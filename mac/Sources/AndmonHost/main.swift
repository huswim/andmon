import AppKit
import Darwin

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let bitrates = [12, 20, 30, 40, 60, 80, 100].map { $0 * 1_000_000 }
    private let session: HostSession
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let statusItem = NSMenuItem(title: HostStatus.disconnected.title, action: nil, keyEquivalent: "")
    private let bitrateMenu = NSMenu()
    private var signalSources: [DispatchSourceSignal] = []
    private var terminating = false

    override init() {
        let bitrate = Self.migrateBitrate(in: .standard)
        session = HostSession(bitrate: bitrate)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()
        item.button?.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Andmon")
        item.button?.toolTip = "Andmon: \(HostStatus.disconnected.title)"
        let menu = NSMenu()
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Resume", action: #selector(resume), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Stop", action: #selector(stop), keyEquivalent: "s").target = self
        menu.addItem(.separator())
        let bitrateItem = NSMenuItem(title: "Bitrate", action: nil, keyEquivalent: "")
        bitrateItem.submenu = bitrateMenu
        menu.addItem(bitrateItem)
        configureBitrateMenu()
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        session.onStatus = { [weak self] status in
            self?.statusItem.title = status.title
            self?.item.button?.toolTip = "Andmon: \(status.title)"
        }
        session.resume()
    }

    @objc private func resume() { session.resume() }
    @objc private func stop() { session.stop() }
    @objc private func selectBitrate(_ sender: NSMenuItem) {
        guard let bitrate = sender.representedObject as? Int else { return }
        UserDefaults.standard.set(bitrate, forKey: "bitrate")
        updateBitrateChecks(selected: bitrate)
        session.setBitrate(bitrate)
    }

    @objc private func quit() {
        guard !terminating else { return }
        terminating = true
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

    private func configureBitrateMenu() {
        let selected = UserDefaults.standard.integer(forKey: "bitrate")
        for bitrate in Self.bitrates {
            let menuItem = NSMenuItem(
                title: "\(bitrate / 1_000_000) Mbps",
                action: #selector(selectBitrate(_:)),
                keyEquivalent: ""
            )
            menuItem.target = self
            menuItem.representedObject = bitrate
            bitrateMenu.addItem(menuItem)
        }
        updateBitrateChecks(selected: Self.bitrates.contains(selected) ? selected : CaptureEncoder.defaultBitrate)
    }

    private func updateBitrateChecks(selected: Int) {
        for item in bitrateMenu.items {
            item.state = (item.representedObject as? Int) == selected ? .on : .off
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
        bitrates.contains(bitrate) ? bitrate : nil
    }
}

private func runVirtualDisplayGate() -> Never {
    do {
        let display = try VirtualDisplay()
        print("PASS virtual display gate: displayID=\(display.displayID), logical=1336x834, backing=2672x1668")
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
