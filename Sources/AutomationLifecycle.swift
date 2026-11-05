import Foundation

// User intent survives transient display errors. Time and events are supplied by
// the caller so sleep/wake sequences can be tested without sleeping a real Mac.
struct AutomationLifecycle {
    enum Phase: Equatable {
        case awake
        case sleeping
        case waking(until: TimeInterval)
    }

    private(set) var enabled: Bool
    private(set) var phase: Phase = .awake
    private(set) var generation = 0
    private(set) var retryAfter: TimeInterval = 0
    var awaitingReconnect = false

    init(enabled: Bool) { self.enabled = enabled }

    var isSleeping: Bool { phase == .sleeping }

    mutating func setUserEnabled(_ value: Bool) {
        enabled = value
        generation += 1
        retryAfter = 0
        awaitingReconnect = false
    }

    mutating func sleep() {
        guard !isSleeping else { return }
        phase = .sleeping
        generation += 1
        retryAfter = 0
    }

    mutating func wake(at now: TimeInterval) {
        phase = .waking(until: now + 3)
        generation += 1
        retryAfter = 0
        awaitingReconnect = false
    }

    func allowsWork(at now: TimeInterval) -> Bool {
        switch phase {
        case .sleeping: return false
        case .waking(let until) where now < until: return false
        default: return now >= retryAfter
        }
    }

    func acceptsResult(from generation: Int) -> Bool {
        self.generation == generation && !isSleeping
    }

    @discardableResult
    mutating func recoveryFailed(from generation: Int, at now: TimeInterval) -> Bool {
        guard acceptsResult(from: generation) else { return false }
        retryAfter = now + 3
        return true
    }

    func action(at now: TimeInterval, target: String?, displays: [DisplayState],
                ownsDisabledDisplay: Bool) -> DisplayAction {
        guard allowsWork(at: now) else { return .none }
        return decideDisplayAction(enabled: enabled, target: target, displays: displays,
            ownsDisabledDisplay: ownsDisabledDisplay, awaitingReconnect: awaitingReconnect)
    }

    func disconnectAction(at now: TimeInterval, target: String?, displays: [DisplayState],
                          ownsDisabledDisplay: Bool) -> DisplayAction {
        guard allowsWork(at: now), ownsDisabledDisplay else { return .none }
        if let monitor = displays.first(where: { !$0.builtIn && $0.uuid == target }), !monitor.active {
            return .none // Connected but inactive is standby, not an unplug.
        }
        return .restoreInternal
    }
}
