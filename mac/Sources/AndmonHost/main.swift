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

    override init() {
        let bitrate = Self.migrateBitrate(in: .standard)
        session = HostSession(bitrate: bitrate)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()

        let vm = SessionViewModel()
        self.viewModel = vm
        vm.onResume = { [weak self] in self?.resume() }
        vm.onStop = { [weak self] in self?.stop() }
        vm.onQuit = { [weak self] in self?.quit() }
        vm.onBitrateChange = { [weak self] bitrate in
            UserDefaults.standard.set(bitrate, forKey: "bitrate")
            self?.session.setBitrate(bitrate)
        }
        vm.bitrateMbps = Double(Self.migrateBitrate(in: .standard)) / 1_000_000.0

        session.onStatus = { [weak self] status in
            self?.viewModel?.status = status
            self?.updateStatusItem(status: status)
        }
        session.onMetrics = { [weak self] metrics in
            self?.viewModel?.metrics = metrics
        }

        let popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 320)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PopoverView(viewModel: vm))
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
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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

if CommandLine.arguments.contains("--virtual-display-gate") {
    runVirtualDisplayGate()
} else if CommandLine.arguments.contains("--aoa-gate") {
    runAOAGate()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
