import AppKit
import ServiceManagement

private let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"

private let displayReconfiguration: CGDisplayReconfigurationCallBack = { display, flags, context in
    guard let context, !flags.contains(.beginConfigurationFlag) else { return }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
    // Never reconfigure from inside CoreGraphics' own callback.
    DispatchQueue.main.async { [weak delegate] in delegate?.displayChanged(display, flags: flags) }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let defaults = UserDefaults.standard
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var pending: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var lifecycle = AutomationLifecycle(enabled: UserDefaults.standard.bool(forKey: "automationEnabled"))
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var message = "Choose your external monitor"
    private var failure: String?
    private var lastAttempt = Date.distantPast
    private var recoveryProcess: Process?
    private var recoveryIsProbe = false
    private var physicalWatcher: PhysicalDisplayWatcher?
    private var externalIDsAtDisable: Set<CGDirectDisplayID> = []
    private var servicesAtDisable: Set<UInt64> = []
    private var awaitingReconnect: Bool {
        get { lifecycle.awaitingReconnect }
        set { lifecycle.awaitingReconnect = newValue }
    }
    private var connectionGeneration = 0
    private var quitState = QuitState()
    private var exitingDuplicate = false
    private var enabled: Bool {
        get { lifecycle.enabled }
        set { lifecycle.setUserEnabled(newValue); defaults.set(newValue, forKey: "automationEnabled") }
    }
    private var target: String? { defaults.string(forKey: "targetUUID") }
    private var ownedID: CGDirectDisplayID? {
        get { (defaults.object(forKey: "disabledInternalID") as? NSNumber)?.uint32Value }
        set {
            if let newValue { defaults.set(newValue, forKey: "disabledInternalID") }
            else {
                defaults.removeObject(forKey: "disabledInternalID")
                defaults.removeObject(forKey: "disabledInternalUUID")
                defaults.removeObject(forKey: "disabledInternalBootTime")
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").count <= 1 else {
            exitingDuplicate = true
            NSApp.terminate(nil); return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // This update changes recovery semantics. Require an explicit resume after updating.
        if defaults.integer(forKey: "recoveryVersion") < 3 {
            enabled = false; defaults.set(3, forKey: "recoveryVersion")
        }
        Diagnostics.record("Panel Off \(appVersion) started; automation=\(enabled); recorded ID=\(ownedID.map(String.init) ?? "none")\n\(Displays.snapshot())")
        statusItem.button?.image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "Panel Off")
        let menu = NSMenu(); menu.autoenablesItems = false; menu.delegate = self; statusItem.menu = menu
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.displayChanged(0, flags: []) })
        CGDisplayRegisterReconfigurationCallback(displayReconfiguration, Unmanaged.passUnretained(self).toOpaque())
        physicalWatcher = PhysicalDisplayWatcher()
        physicalWatcher?.onDisconnect = { [weak self] id in
            guard let self, self.servicesAtDisable.contains(id) else { return }
            self.restoreAfterDisconnect(reason: "physical service removed \(id)")
        }
        physicalWatcher?.onConnect = { [weak self] in
            guard let self else { return }
            self.connectionGeneration += 1
            self.awaitingReconnect = false
            self.schedule(delay: 2)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
            [weak self] _ in self?.prepareForSleep(reason: "system sleep")
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) {
            [weak self] _ in self?.prepareForSleep(reason: "screen sleep")
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
            [weak self] _ in self?.resumeAfterWake(reason: "system wake")
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) {
            [weak self] _ in self?.resumeAfterWake(reason: "screen wake")
        })
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.reconcile() }
        RunLoop.main.add(timer!, forMode: .common)
        schedule()
    }

    private func schedule(delay: TimeInterval = 1) {
        guard !quitState.started, !lifecycle.isSleeping else { return }
        pending?.cancel()
        let generation = lifecycle.generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.lifecycle.acceptsResult(from: generation) else { return }
            self.reconcile()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelRecovery() {
        let process = recoveryProcess
        recoveryProcess = nil
        if let process, process.isRunning { process.terminate() }
    }

    private func prepareForSleep(reason: String) {
        guard !quitState.started else { return }
        lifecycle.sleep()
        pending?.cancel()
        cancelRecovery()
        failure = nil
        message = "Sleeping — automation \(enabled ? "enabled" : "paused")"
        Diagnostics.record("\(reason): suspended display work; automation=\(enabled) generation=\(lifecycle.generation)")
    }

    private func resumeAfterWake(reason: String) {
        guard !quitState.started else { return }
        cancelRecovery()
        lifecycle.wake(at: now)
        failure = nil
        lastAttempt = .distantPast
        message = "Waiting for displays to wake"
        Diagnostics.record("\(reason): settling for three seconds; automation=\(enabled) generation=\(lifecycle.generation)")
        schedule(delay: 3)
    }

    func displayChanged(_ id: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        guard lifecycle.allowsWork(at: now), !quitState.started else { return }
        if awaitingReconnect, flags.contains(.addFlag), Displays.uuid(id) == target {
            connectionGeneration += 1
            awaitingReconnect = false
            Diagnostics.record("selected external monitor reconnected id=\(id)")
        }
        if ownedID != nil {
            let current = Set(((try? Displays.list()) ?? []).filter { !$0.builtIn }.map(\.id))
            let removed = flags.contains(.removeFlag) && externalIDsAtDisable.contains(id)
            if removed || !externalIDsAtDisable.isSubset(of: current) {
                restoreAfterDisconnect(reason: "display topology changed id=\(id) flags=\(flags.rawValue)")
                return
            }
        }
        schedule(delay: 0)
    }

    private func restoreAfterDisconnect(reason: String) {
        guard ownedID != nil, lifecycle.allowsWork(at: now), !quitState.started else { return }
        let displays = (try? Displays.list()) ?? []
        guard lifecycle.disconnectAction(at: now, target: target, displays: displays.map(\.state),
            ownsDisabledDisplay: true) == .restoreInternal else {
            Diagnostics.record("deferred disconnect during monitor standby: \(reason); automation=\(enabled)")
            return
        }
        if recoveryProcess != nil && !recoveryIsProbe { return }
        awaitingReconnect = true
        pending?.cancel()
        lastAttempt = Date()
        Diagnostics.record("disconnect recovery immediately: \(reason)\n\(Displays.snapshot())")
        // Keep potentially blocking display transactions off the main thread so sleep
        // notifications and helper timeouts can still be processed promptly.
        retryRecoveryInFreshProcess()
    }

    private func restore() throws {
        try Displays.requestInternalRestore()
        // Keep ownership until the panel actually appears; polling retries restoration.
        if try Displays.internalPanelIsOnline() {
            ownedID = nil
        } else {
            throw DisplayFailure.message("Waiting for the built-in display to return; retrying automatically.")
        }
    }

    private func reconcile() {
        guard lifecycle.allowsWork(at: now), !quitState.started, Date().timeIntervalSince(lastAttempt) >= 2 else { return }
        guard recoveryProcess == nil else { return }
        do {
            let displays = try Displays.list()
            let action = lifecycle.action(at: now, target: target,
                displays: displays.map(\.state), ownsDisabledDisplay: ownedID != nil)
            switch action {
            case .restoreInternal:
                lastAttempt = Date()
                if enabled { restoreAfterDisconnect(reason: "selected monitor disappeared during polling") }
                else { retryRecoveryInFreshProcess() }
            case .disableInternal:
                guard let panel = displays.first(where: { $0.builtIn && $0.active }) else { break }
                guard let physicalWatcher, !physicalWatcher.services.isEmpty else {
                    throw DisplayFailure.message("Cannot monitor the physical display connection; keeping the internal display on.")
                }
                // Recheck the selected monitor immediately before changing the configuration.
                guard try Displays.list().contains(where: { !$0.builtIn && $0.active && $0.uuid == target }) else { break }
                ownedID = panel.id
                defaults.set(panel.uuid, forKey: "disabledInternalUUID")
                defaults.set(Displays.bootTime, forKey: "disabledInternalBootTime")
                defaults.synchronize()
                externalIDsAtDisable = Set(displays.filter { !$0.builtIn && $0.active }.map(\.id))
                servicesAtDisable = physicalWatcher.services
                lastAttempt = Date()
                try Displays.configure(panel.id, enabled: false)
                failure = nil
            case .none:
                // A fresh process checks disconnects even when this app's display list is stale.
                if ownedID != nil, displays.contains(where: { !$0.builtIn && $0.active && $0.uuid == target }) {
                    externalIDsAtDisable = Set(displays.filter { !$0.builtIn }.map(\.id))
                    servicesAtDisable = physicalWatcher?.services ?? []
                    retryRecoveryInFreshProcess(probe: true)
                }
            }
            if action == .restoreInternal { failure = nil }
            if failure == nil {
                if !enabled { message = "Automation paused" }
                else if awaitingReconnect {
                    message = ownedID != nil ? "Restoring internal display…" : "Waiting for selected monitor to reconnect"
                }
                else if displays.contains(where: { !$0.builtIn && $0.active && $0.uuid == target }) {
                    message = (try Displays.list().contains(where: { $0.builtIn && $0.active }))
                        ? "Waiting to disable internal display" : "Internal display off"
                } else { message = "Waiting for selected monitor" }
            }
        } catch {
            failure = error.localizedDescription
            Diagnostics.record("reconcile error: \(error.localizedDescription)")
            message = "Display change needs attention"
            lifecycle.recoveryFailed(from: lifecycle.generation, at: now)
            if ownedID != nil {
                retryRecoveryInFreshProcess()
            }
        }
        statusItem.button?.toolTip = "Panel Off — \(message)"
    }

    private func retryRecoveryInFreshProcess(probe: Bool = false) {
        if let current = recoveryProcess, recoveryIsProbe && !probe {
            recoveryProcess = nil
            if current.isRunning { current.terminate() }
        }
        guard recoveryProcess == nil, let executable = Bundle.main.executableURL else { return }
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["--recover-panel", probe ? (target ?? "-") : "-"]
        if let recorded = Displays.recordedPanel() {
            process.arguments?.append(contentsOf: [String(recorded.id), String(recorded.bootTime)])
        }
        process.standardOutput = output; process.standardError = output
        recoveryProcess = process
        recoveryIsProbe = probe
        let generationAtStart = connectionGeneration
        let lifecycleGeneration = lifecycle.generation
        process.terminationHandler = { [weak self] process in
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8) ?? "Recovery failed"
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.recoveryProcess === process else { return }
                self.recoveryProcess = nil
                Diagnostics.record("helper exit=\(process.terminationStatus) reason=\(process.terminationReason.rawValue) output=\(detail.trimmingCharacters(in: .whitespacesAndNewlines))")
                if self.quitState.started {
                    if process.terminationStatus == 0 && detail.hasPrefix("Internal display restored") { self.ownedID = nil }
                    self.finishQuit()
                    return
                }
                guard self.lifecycle.acceptsResult(from: lifecycleGeneration) else {
                    Diagnostics.record("ignored recovery result from before sleep/wake or a user setting change")
                    return
                }
                if process.terminationStatus == 0 && detail.hasPrefix("Internal display restored") {
                    if probe && self.connectionGeneration == generationAtStart { self.awaitingReconnect = true }
                    self.ownedID = nil; self.failure = nil
                    // User actions already set the toggle. Automatic callbacks never change it.
                    self.message = "Internal display restored"
                } else if process.terminationStatus != 0 {
                    self.lifecycle.recoveryFailed(from: lifecycleGeneration, at: self.now)
                    let detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.failure = detail.isEmpty ? "Recovery helper exited with status \(process.terminationStatus). Copy Diagnostics." : detail
                    self.message = "Recovery failed — retrying; automation \(self.enabled ? "enabled" : "paused")"
                }
            }
        }
        do {
            try process.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self, weak process] in
                guard let self, let process, self.recoveryProcess === process, process.isRunning else { return }
                Diagnostics.record("recovery helper timed out; terminating pid=\(process.processIdentifier)")
                process.terminate()
            }
        } catch {
            recoveryProcess = nil; failure = error.localizedDescription
            lifecycle.recoveryFailed(from: lifecycleGeneration, at: now)
            Diagnostics.record("helper launch failed: \(error.localizedDescription)")
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        add(message, to: menu)
        add("Panel Off \(appVersion)", to: menu)
        if let failure { add(failure, to: menu) }
        menu.addItem(.separator())
        let automation = add("Automatically Turn Off Internal Display", action: #selector(toggleAutomation), to: menu)
        automation.state = enabled ? .on : .off
        automation.isEnabled = target != nil && Displays.setEnabled != nil
        let monitorItem = add("Monitor", to: menu)
        let monitors = NSMenu(); monitors.autoenablesItems = false
        monitorItem.submenu = monitors
        monitorItem.isEnabled = true
        var external: [Display] = []
        do { external = try Displays.list(includeNames: true).filter { !$0.builtIn && $0.active } }
        catch { add(error.localizedDescription, to: monitors) }
        if external.isEmpty { add("No external displays detected", to: monitors) }
        if let target, !external.contains(where: { $0.uuid == target }) {
            let saved = add("\(defaults.string(forKey: "targetName") ?? "Selected monitor") (disconnected)", to: monitors)
            saved.state = .on
        }
        for display in external {
            let item = add("\(display.name) · \(display.uuid.prefix(8))", action: #selector(selectMonitor(_:)), to: monitors)
            item.representedObject = [display.uuid, display.name]
            item.state = display.uuid == target ? .on : .off
        }
        if monitors.items.isEmpty { add("Connect your external monitor first", to: monitors) }
        menu.addItem(.separator())
        add("Restore Internal Display and Pause", action: #selector(restoreAndPause), to: menu)
        add("Copy Diagnostics", action: #selector(copyDiagnostics), to: menu)
        let login = add("Launch at Login", action: #selector(toggleLogin), to: menu)
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        if SMAppService.mainApp.status == .requiresApproval { login.title = "Allow Launch at Login in System Settings…" }
        menu.addItem(.separator())
        add("Quit Panel Off", action: #selector(quit), to: menu)
    }

    @discardableResult private func add(_ title: String, action: Selector? = nil, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; item.isEnabled = action != nil; menu.addItem(item); return item
    }
    @objc private func selectMonitor(_ sender: NSMenuItem) {
        guard let values = sender.representedObject as? [String] else { return }
        // Restore before switching targets so the old selection cannot leave a panel stranded.
        enabled = false
        do { try restore() } catch { failure = error.localizedDescription; return }
        defaults.set(values[0], forKey: "targetUUID"); defaults.set(values[1], forKey: "targetName")
        enabled = true; awaitingReconnect = false; failure = nil; schedule()
    }
    @objc private func toggleAutomation() {
        enabled.toggle(); awaitingReconnect = false; failure = nil; lastAttempt = .distantPast; reconcile()
    }
    @objc private func restoreAndPause() {
        enabled = false; defaults.synchronize(); failure = nil
        cancelRecovery()
        message = "Restoring internal display…"
        Diagnostics.record("manual Restore and Pause requested\n\(Displays.snapshot())")
        // Always attempt recovery, even when a previous run lost the saved ownership record.
        retryRecoveryInFreshProcess()
    }
    @objc private func copyDiagnostics() {
        let history = (try? String(contentsOf: Diagnostics.url, encoding: .utf8)) ?? "No recovery log yet"
        let report = "Panel Off \(appVersion)\nmacOS \(ProcessInfo.processInfo.operatingSystemVersionString)\nStatus: \(message)\nError: \(failure ?? "none")\nAutomation: \(enabled)\nLifecycle: \(lifecycle.phase) generation=\(lifecycle.generation)\nRecorded internal ID: \(ownedID.map(String.init) ?? "none")\nPhysical services: \(physicalWatcher?.services.sorted() ?? [])\nAwaiting reconnect: \(awaitingReconnect)\n\(Displays.snapshot())\n\nRecovery history:\n\(history.suffix(64000))"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            else if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { failure = error.localizedDescription }
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if exitingDuplicate { return .terminateNow }
        let action = quitState.begin(needsRecovery: ownedID != nil)
        if action == .wait { return .terminateLater }
        enabled = false
        defaults.synchronize()
        pending?.cancel(); timer?.invalidate()
        physicalWatcher = nil
        if action == .exitNow {
            Diagnostics.record("quit: no disabled panel recorded; exiting immediately")
            return .terminateNow
        }
        Diagnostics.record("quit: automation paused; one recovery attempt with a six-second deadline")
        retryRecoveryInFreshProcess()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.finishQuit() }
        return .terminateLater
    }

    private func finishQuit() {
        guard quitState.finish() else { return }
        Diagnostics.record("quit: exiting regardless of recovery result")
        if let process = recoveryProcess, process.isRunning { process.terminate() }
        recoveryProcess = nil
        NSApp.reply(toApplicationShouldTerminate: true)
    }
    func applicationWillTerminate(_ notification: Notification) {
        CGDisplayRemoveReconfigurationCallback(displayReconfiguration, Unmanaged.passUnretained(self).toOpaque())
        physicalWatcher = nil; pending?.cancel(); timer?.invalidate()
    }
}

if CommandLine.arguments.contains("--startup-check") {
    let delegate = AppDelegate()
    withExtendedLifetime(delegate) { print("Panel Off \(appVersion) menu bar controller initialized successfully") }
} else if [2, 3, 5].contains(CommandLine.arguments.count), CommandLine.arguments[1] == "--recover-panel" {
    do {
        if CommandLine.arguments.count >= 3, CommandLine.arguments[2] != "-" {
            let target = CommandLine.arguments[2]
            if try targetIsConnected(target, displays: Displays.list().map(\.state)) {
                print("Selected monitor remains connected")
                exit(0)
            }
        }
        var recorded: RecordedPanel?
        if CommandLine.arguments.count == 5, let id = UInt32(CommandLine.arguments[3]), let boot = Double(CommandLine.arguments[4]) {
            recorded = RecordedPanel(id: id, bootTime: boot)
        }
        try Displays.recoverInternalPanel(recorded: recorded)
        print("Internal display restored")
    } catch { Diagnostics.record("helper recovery failed: \(error.localizedDescription)"); fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--status") {
    print("Panel Off \(appVersion)")
    print("Display disable API: \(Displays.setEnabled == nil ? "unavailable" : "available")")
    print(Displays.snapshot())
    do {
        let displays = try Displays.list()
        if displays.isEmpty { print("No displays visible to this process. Run from Terminal in your desktop session.") }
        for display in displays {
            print("\(display.id)\t\(display.builtIn ? "internal" : "external")\t\(display.active ? "active" : "inactive")\t\(display.uuid)\t\(display.name)")
        }
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--restore") {
    // Emergency recovery uses a fresh WindowServer connection and never disables a screen.
    let defaults = UserDefaults.standard
    defaults.set(false, forKey: "automationEnabled")
    defaults.synchronize()
    do { try Displays.recoverInternalPanel(); print("Internal display restored. Automation paused.") }
    catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
