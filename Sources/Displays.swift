import AppKit
import Darwin

struct Display {
    let id: CGDirectDisplayID
    let uuid: String
    let name: String
    let builtIn: Bool
    let active: Bool
    var state: DisplayState { DisplayState(uuid: uuid, builtIn: builtIn, active: active) }
}

enum DisplayFailure: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

enum Displays {
    typealias SetEnabled = @convention(c) (CGDisplayConfigRef, CGDirectDisplayID, Bool) -> Int32
    typealias GetDisplayList = @convention(c) (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> Int32
    // Keep the framework loaded for the lifetime of the resolved function pointer.
    static let framework = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)
    static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    static let getDisplayList: GetDisplayList? = {
        guard let skyLight, let symbol = dlsym(skyLight, "CGSGetDisplayList") else { return nil }
        return unsafeBitCast(symbol, to: GetDisplayList.self)
    }()
    static let setEnabled: SetEnabled? = {
        guard let framework, let symbol = dlsym(framework, "CGSConfigureDisplayEnabled") else { return nil }
        return unsafeBitCast(symbol, to: SetEnabled.self)
    }()

    static func uuid(_ id: CGDirectDisplayID) -> String? {
        guard let value = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, value) as String
    }

    static func list(includeNames: Bool = false) throws -> [Display] {
        // Helpers must never call NSScreen: it registers a GUI application and can abort.
        let screens = includeNames ? NSScreen.screens : []
        var ids = [CGDirectDisplayID](repeating: 0, count: 64)
        var count: UInt32 = 0
        let error = CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count)
        guard error == .success else { throw DisplayFailure.message("Cannot read displays (\(error.rawValue)).") }
        let discovered = Array(ids.prefix(Int(count)))
        // Zero online displays is a valid and crucial recovery state after unplugging.
        return discovered.compactMap { id in
            guard let uuid = uuid(id) else { return nil }
            let builtIn = CGDisplayIsBuiltin(id) != 0
            let screen = screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
            }
            let name = screen?.localizedName ?? (builtIn ? "Built-in Display" : "External Display")
            // Mirrored displays can be online without being active.
            let active = CGDisplayIsActive(id) != 0 || CGDisplayIsInMirrorSet(id) != 0
            return Display(id: id, uuid: uuid, name: name, builtIn: builtIn, active: active)
        }
    }

    static var bootTime: TimeInterval {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 {
            return TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000
        }
        // Unlike ProcessInfo.systemUptime, this clock includes time spent asleep.
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let elapsed = Double(mach_continuous_time()) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
        return Date().timeIntervalSince1970 - elapsed
    }

    static func knownIDs() throws -> [CGDirectDisplayID] {
        guard let getDisplayList else {
            throw DisplayFailure.message("CGSGetDisplayList is unavailable; cannot locate offline displays.")
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: 64)
        var count: UInt32 = 0
        let result = getDisplayList(UInt32(ids.count), &ids, &count)
        guard result == 0 else { throw DisplayFailure.message("CGSGetDisplayList failed (\(result)).") }
        return Array(ids.prefix(Int(count)))
    }

    static func recoveryID() throws -> CGDirectDisplayID? {
        internalRecoveryID(try knownIDs().map { id in
            RecoveryCandidate(id: id, builtIn: CGDisplayIsBuiltin(id) != 0,
                hasHardware: CGDisplayIsOnline(id) != 0 || CGDisplayVendorNumber(id) != 0
                    || CGDisplayModelNumber(id) != 0 || CGDisplaySerialNumber(id) != 0)
        })
    }

    static func recordedPanel() -> RecordedPanel? {
        let defaults = UserDefaults.standard
        guard let id = defaults.object(forKey: "disabledInternalID") as? NSNumber,
              let boot = defaults.object(forKey: "disabledInternalBootTime") as? NSNumber else { return nil }
        return RecordedPanel(id: id.uint32Value, bootTime: boot.doubleValue)
    }

    static func requestInternalRestore(recorded: RecordedPanel? = nil) throws {
        let candidates = try knownIDs().map { id in
            RecoveryCandidate(id: id, builtIn: CGDisplayIsBuiltin(id) != 0,
                hasHardware: CGDisplayVendorNumber(id) != 0 || CGDisplayModelNumber(id) != 0 || CGDisplayIsOnline(id) != 0)
        }
        let live = internalRecoveryID(candidates)
        let cached = cachedRecoveryID(recorded ?? recordedPanel(), currentBootTime: bootTime, candidates: candidates)
        guard let id = live ?? cached else {
            throw DisplayFailure.message("The full macOS display list has no identifiable built-in panel.")
        }
        Diagnostics.record("restore internal ID=\(id) source=\(live == nil ? "recorded before disable" : "current list")\n\(snapshot())")
        try configure(id, enabled: true, verifiedRecordedRecovery: live == nil)
    }

    static func internalPanelIsOnline() throws -> Bool {
        guard let id = try recoveryID() else { return false }
        return CGDisplayIsOnline(id) != 0 && (CGDisplayIsActive(id) != 0 || CGDisplayIsInMirrorSet(id) != 0)
    }

    static func snapshot() -> String {
        do {
            let ids = try knownIDs()
            return "known display IDs=\(ids)\n" + ids.map { id in
                "id=\(id) uuid=\(uuid(id) ?? "absent") builtIn=\(CGDisplayIsBuiltin(id)) online=\(CGDisplayIsOnline(id)) active=\(CGDisplayIsActive(id)) vendor=\(CGDisplayVendorNumber(id)) model=\(CGDisplayModelNumber(id))"
            }.joined(separator: "\n")
        } catch { return error.localizedDescription }
    }

    static func recoverInternalPanel(recorded: RecordedPanel? = nil) throws {
        Diagnostics.record("recovery start\n\(snapshot())")
        for attempt in 1...3 {
            do { try requestInternalRestore(recorded: recorded) }
            catch { Diagnostics.record("recovery attempt \(attempt): \(error.localizedDescription)") }
            for _ in 0..<4 {
                Thread.sleep(forTimeInterval: 0.15)
                if (try? internalPanelIsOnline()) == true {
                    Diagnostics.record("recovery verified panel online\n\(snapshot())")
                    return
                }
            }
        }
        // Undo the session override using the public API, independent of cached panel IDs.
        // This can also restore saved monitor positions/resolutions.
        Diagnostics.record("targeted recovery failed; restoring user's saved display configuration")
        CGRestorePermanentDisplayConfiguration()
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.2)
            if (try? internalPanelIsOnline()) == true {
                Diagnostics.record("saved configuration recovery verified\n\(snapshot())")
                return
            }
        }
        Diagnostics.record("recovery failed verification\n\(snapshot())")
        throw DisplayFailure.message("Panel did not return after enable requests and saved-configuration recovery. Copy Diagnostics from the menu.")
    }

    static func configure(_ id: CGDirectDisplayID, enabled: Bool, verifiedRecordedRecovery: Bool = false) throws {
        guard let setEnabled else { throw DisplayFailure.message("Display disable API is unavailable on this macOS version.") }
        guard CGDisplayIsBuiltin(id) != 0 || (enabled && verifiedRecordedRecovery) else {
            throw DisplayFailure.message("Refusing to change a display that is not the built-in panel.")
        }
        if !enabled {
            guard try list().contains(where: { !$0.builtIn && $0.active }) else {
                throw DisplayFailure.message("An active external display is required.")
            }
        }
        var configuration: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&configuration)
        Diagnostics.record("configuration begin id=\(id) enable=\(enabled) result=\(begin.rawValue)")
        guard begin == .success, let configuration else {
            throw DisplayFailure.message("Cannot begin display configuration (\(begin.rawValue)).")
        }
        let result = setEnabled(configuration, id, enabled)
        Diagnostics.record("configuration enable id=\(id) enable=\(enabled) result=\(result)")
        guard result == 0 else {
            CGCancelDisplayConfiguration(configuration)
            throw DisplayFailure.message("macOS rejected the display change (\(result)).")
        }
        // Session only: never persist a disabled panel in the system's boot configuration.
        let completed = CGCompleteDisplayConfiguration(configuration, .forSession)
        Diagnostics.record("configuration commit id=\(id) enable=\(enabled) result=\(completed.rawValue)")
        guard completed == .success else {
            throw DisplayFailure.message("Cannot apply display configuration (\(completed.rawValue)).")
        }
    }
}
