import Foundation
import IOKit

// Independent of WindowServer: observe the physical display transport disappearing.
final class PhysicalDisplayWatcher {
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private(set) var services: Set<UInt64> = []
    var onConnect: (() -> Void)?
    var onDisconnect: ((UInt64) -> Void)?

    init?() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return nil }
        self.port = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        for serviceClass in ["DCPAVServiceProxy", "IOPortTransportStateDisplayPort"] {
            var added: io_iterator_t = 0
            let context = Unmanaged.passUnretained(self).toOpaque()
            let result = IOServiceAddMatchingNotification(port, kIOFirstMatchNotification,
                IOServiceMatching(serviceClass), { context, iterator in
                    guard let context else { return }
                    Unmanaged<PhysicalDisplayWatcher>.fromOpaque(context).takeUnretainedValue().drain(iterator, adding: true)
                }, context, &added)
            guard result == KERN_SUCCESS else { stop(); return nil }
            iterators.append(added)
            drain(added, adding: true)
            var removed: io_iterator_t = 0
            let removalResult = IOServiceAddMatchingNotification(port, kIOTerminatedNotification,
                IOServiceMatching(serviceClass), { context, iterator in
                    guard let context else { return }
                    Unmanaged<PhysicalDisplayWatcher>.fromOpaque(context).takeUnretainedValue().drain(iterator, adding: false)
                }, context, &removed)
            guard removalResult == KERN_SUCCESS else { stop(); return nil }
            iterators.append(removed)
            drain(removed, adding: false)
        }
        Diagnostics.record("physical watcher started with services=\(services.sorted())")
    }

    private func drain(_ iterator: io_iterator_t, adding: Bool) {
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS else { continue }
            if adding {
                if IOObjectConformsTo(service, "DCPAVServiceProxy") != 0 {
                    let location = IORegistryEntryCreateCFProperty(service, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                    guard location as? String == "External" else { continue }
                }
                if services.insert(id).inserted {
                    Diagnostics.record("physical display service appeared id=\(id)")
                    onConnect?()
                }
            } else if services.remove(id) != nil {
                Diagnostics.record("physical display service disappeared id=\(id)")
                onDisconnect?(id)
            }
        }
    }

    private func stop() {
        if let port { IONotificationPortSetDispatchQueue(port, nil); IONotificationPortDestroy(port) }
        port = nil
        for iterator in iterators { IOObjectRelease(iterator) }
        iterators.removeAll()
    }
    deinit { stop() }
}
