import Foundation

struct DisplayState {
    let uuid: String
    let builtIn: Bool
    let active: Bool
}

enum DisplayAction: Equatable {
    case disableInternal
    case restoreInternal
    case none
}

enum QuitAction: Equatable {
    case exitNow, restoreThenExit, wait
}

struct QuitState {
    private(set) var started = false
    private var replied = false

    mutating func begin(needsRecovery: Bool) -> QuitAction {
        if started { return .wait }
        started = true
        return needsRecovery ? .restoreThenExit : .exitNow
    }

    // Helper success, helper failure and the deadline all finish the same quit request once.
    mutating func finish() -> Bool {
        guard started, !replied else { return false }
        replied = true
        return true
    }
}

struct RecoveryCandidate {
    let id: UInt32
    let builtIn: Bool
    let hasHardware: Bool
}

struct RecordedPanel {
    let id: UInt32
    let bootTime: TimeInterval
}

func cachedRecoveryID(_ recorded: RecordedPanel?, currentBootTime: TimeInterval,
                      candidates: [RecoveryCandidate]) -> UInt32? {
    guard let recorded, abs(recorded.bootTime - currentBootTime) < 5 else { return nil }
    // A current external device must never be mistaken for the previous built-in ID.
    if candidates.contains(where: { $0.id == recorded.id && !$0.builtIn && $0.hasHardware }) { return nil }
    return recorded.id
}

// Prefer the current WindowServer ID, including offline displays. The recorded
// ID is a fallback when unplugging removes the panel from this list altogether.
func internalRecoveryID(_ candidates: [RecoveryCandidate]) -> UInt32? {
    let panels = candidates.filter { $0.builtIn && $0.hasHardware }
    return panels.count == 1 ? panels[0].id : nil
}

// Restoration takes priority over automation. A different external monitor never triggers it.
func decideDisplayAction(enabled: Bool, target: String?, displays: [DisplayState],
                         ownsDisabledDisplay: Bool, awaitingReconnect: Bool = false) -> DisplayAction {
    if !enabled || !targetIsConnected(target, displays: displays) {
        return ownsDisabledDisplay ? .restoreInternal : .none
    }
    // A monitor in standby remains connected. Neither restore nor disable until it wakes.
    guard displays.contains(where: { !$0.builtIn && $0.active && $0.uuid == target }) else { return .none }
    return !awaitingReconnect && displays.contains { $0.builtIn && $0.active } ? .disableInternal : .none
}

func targetIsConnected(_ target: String?, displays: [DisplayState]) -> Bool {
    guard let target else { return false }
    return displays.contains { !$0.builtIn && $0.uuid == target }
}
