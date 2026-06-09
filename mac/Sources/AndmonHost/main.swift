import AppKit
import Darwin
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let bitrates = [12, 20, 30, 40, 60, 80, 100].map { $0 * 1_000_000 }
    private let session: HostSession
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var popover: NSPopover?
    private var viewModel: SessionViewModel?
    private var signalSources: [DispatchSourceSignal] = []
    private var terminating = false
    private var pulseTimer: Timer?
    private var pulseState = false
    private var isAsleep = false

    override init() {
        let bitrate = Self.migrateBitrate(in: .standard)
        let audioEnabled = UserDefaults.standard.object(forKey: "audioEnabled") as? Bool ?? true
        let touchEnabled = UserDefaults.standard.object(forKey: "touchEnabled") as? Bool ?? false
        let modeRaw = UserDefaults.standard.string(forKey: "connectionMode") ?? ""
        let mode = ConnectionMode(rawValue: modeRaw) ?? .wired
        let tabletIP = UserDefaults.standard.string(forKey: "tabletIP") ?? "192.168.35.2"
        session = HostSession(bitrate: bitrate, audioEnabled: audioEnabled, touchEnabled: touchEnabled)
        session.configure(mode: mode, tabletIP: tabletIP)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()
        installWorkspaceNotifications()

        let vm = SessionViewModel()
        self.viewModel = vm
        vm.onResume = { [weak self] in self?.resume() }
        vm.onStop = { [weak self] in self?.stop() }
        vm.onQuit = { [weak self] in self?.quit() }
        vm.onBitrateChange = { [weak self] bitrate in
            UserDefaults.standard.set(bitrate, forKey: "bitrate")
            self?.session.setBitrate(bitrate)
        }
        vm.onAudioToggle = { [weak self] enabled in
            UserDefaults.standard.set(enabled, forKey: "audioEnabled")
            self?.session.setAudioEnabled(enabled)
        }
        vm.onTouchToggle = { [weak self] enabled in
            if enabled {
                let options = ["AXTrustedCheckOptionPrompt" as String: true] as CFDictionary
                let isTrusted = AXIsProcessTrustedWithOptions(options)
                if !isTrusted {
                    self?.viewModel?.touchEnabled = false
                    UserDefaults.standard.set(false, forKey: "touchEnabled")
                    self?.session.setTouchEnabled(false)
                    return
                }
            }
            UserDefaults.standard.set(enabled, forKey: "touchEnabled")
            self?.session.setTouchEnabled(enabled)
        }
        vm.onModeChange = { [weak self] mode in
            UserDefaults.standard.set(mode.rawValue, forKey: "connectionMode")
            self?.updateSessionConfiguration()
        }
        vm.onIPChange = { [weak self] ip in
            UserDefaults.standard.set(ip, forKey: "tabletIP")
            self?.updateSessionConfiguration()
        }
        
        vm.bitrateMbps = Double(Self.migrateBitrate(in: .standard)) / 1_000_000.0
        vm.audioEnabled = UserDefaults.standard.object(forKey: "audioEnabled") as? Bool ?? true
        vm.touchEnabled = UserDefaults.standard.object(forKey: "touchEnabled") as? Bool ?? false
        let modeRaw = UserDefaults.standard.string(forKey: "connectionMode") ?? ""
        vm.connectionMode = ConnectionMode(rawValue: modeRaw) ?? .wired
        vm.tabletIP = UserDefaults.standard.string(forKey: "tabletIP") ?? "192.168.35.2"

        session.onStatus = { [weak self] status in
            self?.viewModel?.status = status
            self?.updateStatusItem(status: status)
        }
        session.onMetrics = { [weak self] metrics in
            self?.viewModel?.metrics = metrics
        }

        let popover = NSPopover()
        popover.behavior = .transient
        let hostingController = NSHostingController(rootView: PopoverView(viewModel: vm))
        popover.contentViewController = hostingController
        popover.contentSize = hostingController.view.fittingSize
        self.popover = popover

        if let button = item.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
            updateStatusItem(status: .disconnected)
        }

        session.resume()
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = item.button, let popover = popover else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            if let vc = popover.contentViewController {
                popover.contentSize = vc.view.fittingSize
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func updateStatusItem(status: HostStatus) {
        guard let button = item.button else { return }
        button.toolTip = "Andmon: \(status.title)"

        let systemName = "display.2"
        guard let image = NSImage(systemSymbolName: systemName, accessibilityDescription: "Andmon") else { return }

        switch status {
        case .disconnected, .stopped:
            stopPulse()
            image.isTemplate = true
            button.image = image
        case .negotiating, .retrying:
            image.isTemplate = false
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemOrange])
            button.image = image.withSymbolConfiguration(config)
            startPulse()
        case .waitingForScreenRecordingPermission:
            stopPulse()
            image.isTemplate = false
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemOrange])
            button.image = image.withSymbolConfiguration(config)
        case .streaming:
            stopPulse()
            image.isTemplate = false
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemBlue])
            button.image = image.withSymbolConfiguration(config)
        case .error:
            stopPulse()
            image.isTemplate = false
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            button.image = image.withSymbolConfiguration(config)
        }
    }

    private func startPulse() {
        guard pulseTimer == nil else { return }
        pulseState = false
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pulseState.toggle()
                self.item.button?.animator().alphaValue = self.pulseState ? 1.0 : 0.3
            }
        }
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        item.button?.alphaValue = 1.0
    }

    private func updateSessionConfiguration() {
        guard let vm = viewModel else { return }
        session.configure(mode: vm.connectionMode, tabletIP: vm.tabletIP)
    }

    private func resume() { session.resume() }
    private func stop() { session.stop() }

    @objc private func quit() {
        guard !terminating else { return }
        terminating = true
        stopPulse()
        session.stop {
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func installSignalHandlers() {
        for code in [SIGINT, SIGTERM] {
            signal(code, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: code, queue: .main)
            source.setEventHandler { [weak self] in self?.quit() }
            source.resume()
            signalSources.append(source)
        }
    }

    private func installWorkspaceNotifications() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(
            self,
            selector: #selector(handleWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(handleDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(handleScreensDidSleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(handleScreensDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
    }

    @objc private func handleWillSleep() {
        guard !isAsleep else { return }
        isAsleep = true
        fputs("System going to sleep; stopping session cleanly\n", stderr)
        performSyncStop()
    }

    @objc private func handleScreensDidSleep() {
        guard !isAsleep else { return }
        isAsleep = true
        fputs("Screens went to sleep; stopping session cleanly\n", stderr)
        performSyncStop()
    }

    @objc private func handleDidWake() {
        guard isAsleep else { return }
        isAsleep = false
        fputs("System woke up; resuming session\n", stderr)
        resume()
    }

    @objc private func handleScreensDidWake() {
        guard isAsleep else { return }
        isAsleep = false
        fputs("Screens woke up; resuming session\n", stderr)
        resume()
    }

    private func performSyncStop() {
        let semaphore = DispatchSemaphore(value: 0)
        session.stop {
            semaphore.signal()
        }
        let result = semaphore.wait(timeout: .now() + 3.0)
        if result == .timedOut {
            fputs("Warning: session stop timed out during sleep transition\n", stderr)
        } else {
            fputs("Session stopped cleanly\n", stderr)
        }
    }

    private static func migrateBitrate(in defaults: UserDefaults) -> Int {
        let bitrate = validBitrate(defaults.integer(forKey: "bitrate"))
            ?? validBitrate(defaults.integer(forKey: "cbrBitrate"))
            ?? CaptureEncoder.defaultBitrate
        defaults.set(bitrate, forKey: "bitrate")
        defaults.removeObject(forKey: "cbrBitrate")
        defaults.removeObject(forKey: "vbrBitrate")
        defaults.removeObject(forKey: "rateControl")
        return bitrate
    }

    private static func validBitrate(_ bitrate: Int) -> Int? {
        let minBitrate = 10 * 1_000_000
        let maxBitrate = 100 * 1_000_000
        return (minBitrate...maxBitrate).contains(bitrate) ? bitrate : nil
    }
}

private func runVirtualDisplayGate() -> Never {
    do {
        let display = try VirtualDisplay()
        print("PASS virtual display gate: displayID=\(display.displayID), logical=1480x924, backing=2960x1848")
        display.close()
        exit(EXIT_SUCCESS)
    } catch {
        fputs("FAIL virtual display gate: \(error.localizedDescription)\n", stderr)
        exit(EXIT_FAILURE)
    }
}

private func runAOAGate() -> Never {
    let transport = USBTransport()
    let semaphore = DispatchSemaphore(value: 0)
    let token = Data("andmon-aoa-gate".utf8)
    let result = AOAGateResult()
    transport.onFrame = { frame in
        if frame.type == .ping {
            _ = try? transport.send(type: .pong, payload: frame.payload)
        } else if frame.type == .pong, frame.payload == token {
            result.markPassed()
            semaphore.signal()
        }
    }
    transport.onDisconnect = { error in
        if result.markFinished() {
            fputs("FAIL AOA gate: \(error.localizedDescription)\n", stderr)
            semaphore.signal()
        }
    }
    do {
        try transport.open()
        try transport.send(type: .ping, payload: token)
        if semaphore.wait(timeout: .now() + 10) == .timedOut {
            result.markFinished()
            fputs("FAIL AOA gate: timed out waiting for PONG\n", stderr)
        } else if result.passed {
            print("PASS AOA gate: accessory bulk IN/OUT and bidirectional PING/PONG")
            transport.close()
            exit(EXIT_SUCCESS)
        }
    } catch {
        fputs("FAIL AOA gate: \(error.localizedDescription)\n", stderr)
    }
    transport.close()
    exit(EXIT_FAILURE)
}

private final class AOAGateResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    private var finished = false

    var passed: Bool { lock.withLock { value } }
    func markPassed() { lock.withLock { value = true; finished = true } }
    @discardableResult
    func markFinished() -> Bool {
        lock.withLock {
            guard !finished else { return false }
            finished = true
            return true
        }
    }
}

private var keepAliveDelegate: AppDelegate?

if CommandLine.arguments.contains("--virtual-display-gate") {
    runVirtualDisplayGate()
} else if CommandLine.arguments.contains("--aoa-gate") {
    runAOAGate()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    keepAliveDelegate = delegate
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
