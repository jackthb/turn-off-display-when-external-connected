import Foundation

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

@main struct LifecycleTests {
    static let panel = DisplayState(uuid: "panel", builtIn: true, active: true)
    static let monitor = DisplayState(uuid: "desk", builtIn: false, active: true)
    static let standby = DisplayState(uuid: "desk", builtIn: false, active: false)
    static let virtual = DisplayState(uuid: "virtual", builtIn: false, active: true)

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw CheckFailure(description: message) }
    }

    static func action(_ state: AutomationLifecycle, at time: TimeInterval,
                       _ displays: [DisplayState] = [panel, monitor], owned: Bool = false) -> DisplayAction {
        state.action(at: time, target: "desk", displays: displays, ownsDisabledDisplay: owned)
    }

    static func main() {
        var failures = 0
        var count = 0
        func scenario(_ name: String, _ body: () throws -> Void) {
            count += 1
            do { try body(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }

        scenario("standby is connected, including the helper's unplug probe") {
            let state = AutomationLifecycle(enabled: true)
            try expect(targetIsConnected("desk", displays: [standby]), "A standby monitor must still be connected")
            try expect(action(state, at: 1, [standby], owned: true) == .none, "Do not restore just because the external becomes inactive")
            try expect(state.disconnectAction(at: 1, target: "desk", displays: [standby], ownsDisabledDisplay: true) == .none,
                "A physical notification during standby must not start recovery")
        }
        scenario("system sleep and wake retain the toggle and reapply the rule") {
            var state = AutomationLifecycle(enabled: true)
            state.sleep()
            try expect(action(state, at: 50, [virtual], owned: true) == .none, "No recovery while sleeping")
            state.wake(at: 100)
            try expect(action(state, at: 102.9) == .none, "Let displays settle for three seconds")
            try expect(action(state, at: 103) == .disableInternal, "Reapply once the selected monitor is awake")
            try expect(state.enabled, "Sleep/wake must not untoggle automation")
        }
        scenario("screen sleep without computer sleep is suspended too") {
            var state = AutomationLifecycle(enabled: true)
            state.sleep() // Both production sleep notifications use this transition.
            try expect(!state.allowsWork(at: 500), "Timer must remain inactive throughout screen sleep")
            state.wake(at: 501)
            try expect(action(state, at: 504) == .disableInternal, "Screen wake must resume the rule")
        }
        scenario("paused automation stays paused through sleep and wake") {
            var state = AutomationLifecycle(enabled: false)
            state.sleep(); state.wake(at: 100)
            try expect(action(state, at: 104) == .none, "Do not enable a paused rule on wake")
            try expect(!state.enabled, "The saved user preference must remain off")
        }
        scenario("recovery timeout never untoggles automation") {
            var state = AutomationLifecycle(enabled: true)
            try expect(state.recoveryFailed(from: state.generation, at: 10), "Accept a current failure")
            try expect(state.enabled, "An automatic recovery timeout must not turn the toggle off")
            try expect(action(state, at: 12) == .none, "Back off after an error")
            try expect(action(state, at: 13) == .disableInternal, "A transient error cannot permanently block retries")
        }
        scenario("failure from a helper canceled by sleep is ignored") {
            var state = AutomationLifecycle(enabled: true)
            let oldJob = state.generation
            state.sleep()
            try expect(!state.recoveryFailed(from: oldJob, at: 10), "A canceled helper is stale")
            try expect(state.retryAfter == 0 && state.enabled, "Stale failure cannot alter current intent or retry state")
        }
        scenario("a pre-sleep helper cannot overwrite wake state") {
            var state = AutomationLifecycle(enabled: true)
            let oldJob = state.generation
            state.sleep(); state.wake(at: 100)
            try expect(!state.acceptsResult(from: oldJob), "Ignore both successful and failed results from the previous cycle")
            try expect(action(state, at: 103) == .disableInternal, "Wake must still apply the rule")
        }
        scenario("wake clears the old reconnect latch") {
            var state = AutomationLifecycle(enabled: true)
            state.awaitingReconnect = true
            state.sleep(); state.wake(at: 10)
            try expect(!state.awaitingReconnect, "The same attached monitor need not be unplugged again after waking")
            try expect(action(state, at: 13) == .disableInternal, "An old reconnect latch must not strand both displays on")
        }
        scenario("unplug while sleeping restores after wake without untoggling") {
            var state = AutomationLifecycle(enabled: true)
            state.sleep()
            try expect(state.disconnectAction(at: 10, target: "desk", displays: [], ownsDisabledDisplay: true) == .none,
                "Do not configure sleeping hardware")
            state.wake(at: 100)
            try expect(action(state, at: 102, [virtual], owned: true) == .none, "Respect the wake grace period even with no monitor")
            try expect(action(state, at: 103, [virtual], owned: true) == .restoreInternal, "Restore if the selected monitor stayed disconnected")
            try expect(state.enabled, "Recovery must preserve the user's rule")
        }
        scenario("monitor wakes later than the computer") {
            var state = AutomationLifecycle(enabled: true)
            state.sleep(); state.wake(at: 10)
            try expect(action(state, at: 14, [panel, standby], owned: true) == .none, "Wait while the monitor is still inactive")
            try expect(action(state, at: 18) == .disableInternal, "Retry when that monitor becomes usable")
            try expect(state.enabled, "A slow monitor must not turn the rule off")
        }
        scenario("duplicate wake notifications settle from the latest notification") {
            var state = AutomationLifecycle(enabled: true)
            state.sleep(); state.wake(at: 100); state.wake(at: 102)
            try expect(action(state, at: 104) == .none, "A timer from the earlier notification cannot bypass settling")
            try expect(action(state, at: 105) == .disableInternal, "Resume after the latest wake grace period")
        }
        scenario("duplicate sleep notifications preserve user intent") {
            var state = AutomationLifecycle(enabled: true)
            state.sleep(); let sleepingGeneration = state.generation; state.sleep()
            try expect(state.generation == sleepingGeneration && state.enabled, "System and screen sleep are the same suspended cycle")
        }
        scenario("wake clears a pre-sleep failure backoff") {
            var state = AutomationLifecycle(enabled: true)
            state.recoveryFailed(from: state.generation, at: 100)
            state.sleep(); state.wake(at: 101)
            try expect(state.retryAfter == 0, "A previous-cycle failure must not block wake")
            try expect(action(state, at: 104) == .disableInternal, "Wake settles and resumes")
        }
        scenario("manual pause during wake defeats an older helper") {
            var state = AutomationLifecycle(enabled: true)
            state.sleep(); state.wake(at: 100)
            let job = state.generation
            state.setUserEnabled(false)
            try expect(!state.acceptsResult(from: job), "The user's newer choice wins")
            try expect(action(state, at: 104, [monitor], owned: true) == .restoreInternal, "Finish restoring without re-disabling")
            try expect(!state.enabled, "Automatic completion cannot re-enable a paused rule")
        }
        scenario("actual awake disconnects still recover, including zombie entries") {
            let state = AutomationLifecycle(enabled: true)
            try expect(state.disconnectAction(at: 10, target: "desk", displays: [virtual], ownsDisabledDisplay: true) == .restoreInternal,
                "Recover when the selected monitor is absent")
            try expect(state.disconnectAction(at: 10, target: "desk", displays: [monitor], ownsDisabledDisplay: true) == .restoreInternal,
                "A physical removal can override a stale active monitor entry")
        }
        scenario("scheduled work from a previous cycle cannot run after another wake") {
            var state = AutomationLifecycle(enabled: true)
            state.wake(at: 10); let scheduled = state.generation
            state.sleep(); state.wake(at: 12)
            try expect(!state.acceptsResult(from: scheduled), "Ignore an already-queued callback that cancellation did not stop")
            try expect(action(state, at: 14) == .none, "Old work cannot bypass the new grace period")
        }
        scenario("twenty repeated sleep and wake cycles keep the rule enabled") {
            var state = AutomationLifecycle(enabled: true)
            for cycle in 0..<20 {
                state.sleep()
                try expect(action(state, at: Double(cycle * 10), [], owned: true) == .none, "No sleeping cycle performs recovery")
                state.wake(at: Double(cycle * 10))
                try expect(action(state, at: Double(cycle * 10 + 3)) == .disableInternal, "Cycle \(cycle) failed to reapply")
                try expect(state.enabled, "Cycle \(cycle) lost user intent")
            }
        }
        scenario("the rule survives reconstruction after automatic errors") {
            var state = AutomationLifecycle(enabled: true)
            state.recoveryFailed(from: state.generation, at: 10)
            state.sleep(); state.wake(at: 20)
            let restarted = AutomationLifecycle(enabled: state.enabled)
            try expect(restarted.enabled && action(restarted, at: 30) == .disableInternal, "The preference available to persistence must still be enabled")
        }
        scenario("another monitor never substitutes for the selected one after wake") {
            var state = AutomationLifecycle(enabled: true)
            state.sleep(); state.wake(at: 10)
            let other = DisplayState(uuid: "another", builtIn: false, active: true)
            try expect(action(state, at: 13, [panel, other]) == .none, "Do not disable for the wrong monitor")
        }
        print("\(count - failures)/\(count) sleep/wake lifecycle scenarios passed")
        if failures != 0 { exit(1) }
    }
}
