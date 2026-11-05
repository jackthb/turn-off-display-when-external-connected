import Foundation

@main struct PolicyTests {
    static func main() {
        let panel = DisplayState(uuid: "panel", builtIn: true, active: true)
        let target = DisplayState(uuid: "desk", builtIn: false, active: true)
        let other = DisplayState(uuid: "other", builtIn: false, active: true)
        let inactive = DisplayState(uuid: "desk", builtIn: false, active: false)
        func check(_ expected: DisplayAction, enabled: Bool = true, selected: String? = "desk",
                   _ displays: [DisplayState], owned: Bool = false) {
            precondition(decideDisplayAction(enabled: enabled, target: selected, displays: displays,
                ownsDisabledDisplay: owned) == expected)
        }
        check(.disableInternal, [panel, target])
        check(.none, [panel, other])
        check(.none, [panel, inactive])
        check(.none, selected: nil, [panel, target])
        check(.none, enabled: false, [panel, target])
        check(.none, [target], owned: true)
        check(.restoreInternal, [], owned: true)
        check(.restoreInternal, [other], owned: true)
        check(.restoreInternal, enabled: false, [target], owned: true)
        check(.none, [other]) // Do not restore a panel disabled by another application.
        check(.disableInternal, [panel, target], owned: true) // Wake re-enabled the panel.
        check(.restoreInternal, selected: nil, [], owned: true)
        // Offline recovery needs neither the original numeric ID, a UUID, nor saved boot metadata.
        let offlinePanel = RecoveryCandidate(id: 23, builtIn: true, hasHardware: true)
        let external = RecoveryCandidate(id: 1, builtIn: false, hasHardware: true)
        let ghost = RecoveryCandidate(id: 2, builtIn: true, hasHardware: false)
        precondition(internalRecoveryID([offlinePanel, external]) == 23)
        precondition(internalRecoveryID([external]) == nil)
        precondition(internalRecoveryID([]) == nil)
        precondition(internalRecoveryID([ghost, offlinePanel]) == 23)
        precondition(internalRecoveryID([ghost]) == nil)
        precondition(internalRecoveryID([offlinePanel, RecoveryCandidate(id: 24, builtIn: true, hasHardware: true)]) == nil)
        // Replay the observed unplug state: only a virtual display remains; panel ID 1 is absent.
        let headless = DisplayState(uuid: "virtual", builtIn: false, active: true)
        check(.restoreInternal, [headless], owned: true)
        let virtualOnly = [RecoveryCandidate(id: 38, builtIn: false, hasHardware: true)]
        let recordedPanel = RecordedPanel(id: 1, bootTime: 1000)
        precondition(cachedRecoveryID(recordedPanel, currentBootTime: 1001, candidates: virtualOnly) == 1)
        precondition(cachedRecoveryID(recordedPanel, currentBootTime: 1001, candidates: []) == 1)
        precondition(cachedRecoveryID(recordedPanel, currentBootTime: 2000, candidates: virtualOnly) == nil)
        precondition(cachedRecoveryID(nil, currentBootTime: 1001, candidates: virtualOnly) == nil)
        precondition(cachedRecoveryID(recordedPanel, currentBootTime: 1001, candidates: [external]) == nil)
        // An old online external entry cannot cause an immediate re-disable after unplug recovery.
        precondition(decideDisplayAction(enabled: true, target: "desk", displays: [panel, target],
            ownsDisabledDisplay: false, awaitingReconnect: true) == .none)
        precondition(decideDisplayAction(enabled: true, target: "desk", displays: [panel, target],
            ownsDisabledDisplay: false, awaitingReconnect: false) == .disableInternal)
        precondition(decideDisplayAction(enabled: true, target: "desk", displays: [headless],
            ownsDisabledDisplay: true, awaitingReconnect: true) == .restoreInternal)
        var immediateQuit = QuitState()
        precondition(immediateQuit.begin(needsRecovery: false) == .exitNow)
        var pendingQuit = QuitState()
        precondition(pendingQuit.begin(needsRecovery: true) == .restoreThenExit)
        precondition(pendingQuit.begin(needsRecovery: true) == .wait)
        precondition(pendingQuit.finish()) // A failed helper must still finish quitting.
        precondition(!pendingQuit.finish()) // Its subsequent deadline must not reply twice.
        var deadlineQuit = QuitState()
        precondition(deadlineQuit.begin(needsRecovery: true) == .restoreThenExit)
        precondition(deadlineQuit.finish()) // A hung helper cannot prevent the deadline finishing.
        precondition(!deadlineQuit.finish())
        print("35 display, recovery and quit checks passed")
    }
}
