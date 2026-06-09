import Foundation
import CoreGraphics

private typealias CGSConnectionID = Int32

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSSetConnectionProperty")
private func CGSSetConnectionProperty(
    _ cid: CGSConnectionID,
    _ targetCID: CGSConnectionID,
    _ property: CFString,
    _ value: CFTypeRef
) -> Int32

struct SessionMetrics: Sendable, Equatable {
    var capturedFPS: Int = 0
    var encodedFPS: Int = 0
    var encodeLatencyAvgMs: Double = 0.0
    var encodeLatencyMaxMs: Double = 0.0
    var encoderInputDrops: Int = 0
    var usbQueueBytes: Int = 0
    var usbVideoDrops: Int = 0
}

enum HostStatus: Equatable {
    case disconnected
    case negotiating
    case retrying
    case waitingForScreenRecordingPermission
    case streaming
    case stopped
    case error(String)

    var title: String {
        switch self {
        case .disconnected: "Disconnected"
        case .negotiating: "Negotiating"
        case .retrying: "Disconnected; retrying shortly"
        case .waitingForScreenRecordingPermission: "Waiting for Screen Recording Permission"
        case .streaming: "Streaming"
        case .stopped: "Stopped"
        case .error(let message): "Error: \(message)"
        }
    }
}

final class HostSession: @unchecked Sendable {
    private let stateQueue = DispatchQueue(label: "dev.andmon.session")
    private var transport: USBTransport?
    private var display: VirtualDisplay?
    private var streamer: CaptureEncoder?
    private var pingToken: Data?
    private var pingPurpose: PingPurpose?
    private var pingTimeoutWorkItem: DispatchWorkItem?
    private var heartbeatWorkItem: DispatchWorkItem?
    private var retryWorkItem: DispatchWorkItem?
    private var restartingEncoder = false
    private var receiverWaiting = false
    private var manuallyStopped = true
    private var currentStatus: HostStatus?
    private var bitrate: Int
    private var audioEnabled = true
    private var touchEnabled = false
    private var isCursorHidden = false
    private var isMouseDown = false
    private var isRuntimeStopping = false
    private var stopCompletions: [@Sendable () -> Void] = []
    var onStatus: (@MainActor (HostStatus) -> Void)?
    var onMetrics: (@MainActor (SessionMetrics) -> Void)?

    init(
        bitrate: Int = CaptureEncoder.defaultBitrate,
        audioEnabled: Bool = true,
        touchEnabled: Bool = false
    ) {
        self.bitrate = bitrate
        self.audioEnabled = audioEnabled
        self.touchEnabled = touchEnabled

        let cid = CGSMainConnectionID()
        _ = CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }

    func setBitrate(_ bitrate: Int) {
        stateQueue.async { [weak self] in
            guard let self, self.bitrate != bitrate else { return }
            self.bitrate = bitrate
            fputs("Selected bitrate=\(bitrate); applying on next encoder start\n", stderr)
            guard !manuallyStopped, let transport, display != nil else { return }
            restartEncoder(using: transport)
        }
    }

    func setAudioEnabled(_ enabled: Bool) {
        stateQueue.async { [weak self] in
            guard let self, self.audioEnabled != enabled else { return }
            self.audioEnabled = enabled
            fputs("Selected audioEnabled=\(enabled); applying on next encoder start\n", stderr)
            guard !manuallyStopped, let transport, display != nil else { return }
            restartEncoder(using: transport)
        }
    }

    func setTouchEnabled(_ enabled: Bool) {
        stateQueue.async { [weak self] in
            guard let self, self.touchEnabled != enabled else { return }
            self.touchEnabled = enabled
            fputs("Selected touchEnabled=\(enabled); applying on next encoder start\n", stderr)
            guard !manuallyStopped, let transport, display != nil else { return }
            restartEncoder(using: transport)
        }
    }

    func resume() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            manuallyStopped = false
            cancelRetry()
            stopRuntime {
                self.stateQueue.async {
                    guard !self.manuallyStopped else { return }
                    self.connect()
                }
            }
        }
    }

    func stop(completion: (@Sendable () -> Void)? = nil) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            if let transport { _ = try? transport.send(type: .stop, payload: Data("Stopped by user".utf8)) }
            manuallyStopped = true
            cancelRetry()
            stopRuntime(completion: completion)
            publish(.stopped)
        }
    }

    private func connect() {
        guard !manuallyStopped, transport == nil else { return }
        publish(.negotiating)
        let transport = USBTransport()
        transport.onFrame = { [weak self, weak transport] frame in
            guard let self, let transport else { return }
            stateQueue.async {
                guard self.transport === transport else { return }
                self.handle(frame)
            }
        }
        transport.onDisconnect = { [weak self, weak transport] error in
            guard let self, let transport else { return }
            stateQueue.async {
                guard self.transport === transport else { return }
                self.failed(error)
            }
        }
        self.transport = transport
        do {
            try transport.open()
        } catch {
            failed(error)
        }
    }

    private func handle(_ frame: WireFrame) {
        do {
            switch frame.type {
            case .hello:
                try handleHello(frame.payload)
            case .ping:
                try transport?.send(type: .pong, payload: frame.payload)
            case .pong:
                guard frame.payload == pingToken else { return }
                let purpose = pingPurpose
                cancelPendingPing()
                if purpose == .negotiation {
                    try startStreaming()
                } else if purpose == .recovery {
                    scheduleRecoveryProbe()
                } else {
                    scheduleHeartbeat()
                }
            case .stop:
                manuallyStopped = true
                cancelRetry()
                stopRuntime()
                publish(.stopped)
            case .keyframeRequest:
                streamer?.requestKeyframe()
            case .error:
                throw SessionError.peer(String(decoding: frame.payload, as: UTF8.self))
            case .touch:
                guard touchEnabled else { return }
                try handleTouch(frame.payload)
            default:
                break
            }
        } catch {
            _ = try? transport?.send(type: .error, payload: diagnostic(error))
            failed(error)
        }
    }

    private func handleTouch(_ payload: Data) throws {
        guard let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let action = json["action"] as? Int else {
            return
        }

        guard let display else { return }
        let displayID = display.displayID

        if action == 3 {
            guard var dx = json["dx"] as? Double,
                  var dy = json["dy"] as? Double else {
                return
            }

            // Detect macOS natural scrolling setting and invert deltas if disabled
            var naturalScroll = true
            if let globalDefaults = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain),
               let swipescroll = globalDefaults["com.apple.swipescrolldirection"] as? Bool {
                naturalScroll = swipescroll
            }
            if !naturalScroll {
                dx = -dx
                dy = -dy
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !self.isCursorHidden {
                    CGDisplayHideCursor(displayID)
                    self.isCursorHidden = true
                }
                let event = CGEvent(
                    scrollWheelEvent2Source: nil,
                    units: .pixel,
                    wheelCount: 2,
                    wheel1: Int32(dy),
                    wheel2: Int32(dx),
                    wheel3: 0
                )
                event?.post(tap: .cghidEventTap)
            }
            return
        }

        guard let x = json["x"] as? Double,
              let y = json["y"] as? Double else {
            return
        }

        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0 && bounds.height > 0 else { return }

        let globalX = bounds.origin.x + CGFloat(x) * bounds.size.width
        let globalY = bounds.origin.y + CGFloat(y) * bounds.size.height
        let point = CGPoint(x: globalX, y: globalY)

        if action == 4 {
            DispatchQueue.main.async {
                guard let event = CGEvent(
                    mouseEventSource: nil,
                    mouseType: .mouseMoved,
                    mouseCursorPosition: point,
                    mouseButton: .left
                ) else {
                    return
                }
                event.post(tap: .cghidEventTap)
            }
            return
        }

        let mouseType: CGEventType
        switch action {
        case 0:
            mouseType = .leftMouseDown
        case 1:
            mouseType = .leftMouseDragged
        case 2:
            mouseType = .leftMouseUp
        default:
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if action == 0 {
                self.isMouseDown = true
            }

            // Always unhide cursor on touch release
            if action == 2 && self.isCursorHidden {
                CGDisplayShowCursor(displayID)
                self.isCursorHidden = false
            }

            // Only post leftMouseUp if the mouse was actually pressed down (to prevent scroll release clicks)
            if action == 2 && !self.isMouseDown {
                return
            }

            if action == 2 {
                self.isMouseDown = false
            }

            guard let event = CGEvent(
                mouseEventSource: nil,
                mouseType: mouseType,
                mouseCursorPosition: point,
                mouseButton: .left
            ) else {
                return
            }
            event.post(tap: .cghidEventTap)
        }
    }

    private func handleHello(_ payload: Data) throws {
        let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        guard json?["panelWidth"] as? Int == 2960, json?["panelHeight"] as? Int == 1848,
              json?["landscape"] as? Bool == true, json?["decoder"] as? String == "video/hevc" else {
            throw SessionError.unsupportedPanel
        }
        guard !restartingEncoder else { return }
        if receiverWaiting {
            receiverWaiting = false
            cancelHeartbeat()
            cancelPendingPing()
        }
        if display == nil {
            display = try VirtualDisplay()
        }
        if let transport, streamer != nil {
            restartEncoder(using: transport)
            return
        }
        guard pingToken == nil else { return }
        try sendConfigurationAndPing(using: transport)
    }

    private func restartEncoder(using transport: USBTransport) {
        guard !restartingEncoder else { return }
        cancelHeartbeat()
        cancelPendingPing()
        publish(.negotiating)
        restartingEncoder = true
        stopEncoder { [weak self, weak transport] in
            guard let self, let transport else { return }
            self.stateQueue.async {
                guard self.transport === transport else { return }
                self.restartingEncoder = false
                guard !self.manuallyStopped else { return }
                self.renegotiateStreaming(using: transport)
            }
        }
    }

    private func renegotiateStreaming(using transport: USBTransport) {
        do {
            if display == nil {
                display = try VirtualDisplay()
            }
            try sendConfigurationAndPing(using: transport)
        } catch {
            failed(error)
        }
    }

    private func sendConfigurationAndPing(using transport: USBTransport?) throws {
        guard let transport else { throw SessionError.incompleteGate }
        let config: [String: Any] = [
            "width": 2960, "height": 1848, "fps": 60,
            "bitrate": bitrate, "dataRateLimit": bitrate, "codec": "video/hevc",
            "audioEnabled": audioEnabled,
            "touchEnabled": touchEnabled,
        ]
        try transport.send(type: .config, payload: try JSONSerialization.data(withJSONObject: config))
        try sendPing(using: transport, purpose: .negotiation)
    }

    private func sendPing(using transport: USBTransport, purpose: PingPurpose) throws {
        let token = Data(UUID().uuidString.utf8)
        pingToken = token
        pingPurpose = purpose
        do {
            try transport.send(type: .ping, payload: token)
            schedulePingTimeout(for: token)
        } catch {
            cancelPendingPing()
            throw error
        }
    }

    private func scheduleHeartbeat() {
        cancelHeartbeat()
        guard !manuallyStopped, streamer != nil, pingToken == nil, let transport else { return }
        let workItem = DispatchWorkItem { [weak self, weak transport] in
            guard let self, let transport else { return }
            self.heartbeatWorkItem = nil
            guard self.transport === transport, self.streamer != nil else { return }
            do {
                try self.sendPing(using: transport, purpose: .heartbeat)
            } catch {
                self.failed(error)
            }
        }
        heartbeatWorkItem = workItem
        stateQueue.asyncAfter(deadline: .now() + 2, execute: workItem)
    }

    private func schedulePingTimeout(for token: Data) {
        pingTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.pingToken == token, let transport else { return }
            let purpose = self.pingPurpose
            self.pingTimeoutWorkItem = nil
            self.pingToken = nil
            self.pingPurpose = nil
            if purpose == .recovery, self.receiverWaiting {
                self.scheduleRecoveryProbe()
            } else {
                self.waitForReceiver(using: transport)
            }
        }
        pingTimeoutWorkItem = workItem
        stateQueue.asyncAfter(deadline: .now() + 3, execute: workItem)
    }

    private func waitForReceiver(using transport: USBTransport) {
        guard !restartingEncoder, !receiverWaiting else { return }
        cancelHeartbeat()
        cancelPendingPing()
        publish(.negotiating)
        receiverWaiting = true
        restartingEncoder = true
        deactivateDisplayAndStopEncoder { [weak self, weak transport] in
            guard let self, let transport else { return }
            self.stateQueue.async {
                guard self.transport === transport else { return }
                self.restartingEncoder = false
                guard !self.manuallyStopped else { return }
                self.probeReceiver(using: transport)
            }
        }
    }

    private func probeReceiver(using transport: USBTransport) {
        guard receiverWaiting, pingToken == nil else { return }
        do {
            try sendPing(using: transport, purpose: .recovery)
        } catch {
            failed(error)
        }
    }

    private func scheduleRecoveryProbe() {
        cancelHeartbeat()
        guard receiverWaiting, pingToken == nil, let transport else { return }
        let workItem = DispatchWorkItem { [weak self, weak transport] in
            guard let self, let transport else { return }
            self.heartbeatWorkItem = nil
            guard self.transport === transport else { return }
            self.probeReceiver(using: transport)
        }
        heartbeatWorkItem = workItem
        stateQueue.asyncAfter(deadline: .now() + 2, execute: workItem)
    }

    private func deactivateDisplayAndStopEncoder(completion: @escaping @Sendable () -> Void) {
        let displayToClose = display
        display = nil
        stopEncoder {
            displayToClose?.close()
            completion()
        }
    }

    private func stopEncoder(completion: @escaping @Sendable () -> Void) {
        let streamerToStop = streamer
        streamer = nil
        guard let streamerToStop else {
            completion()
            return
        }
        streamerToStop.stop {
            completion()
        }
    }

    private func cancelHeartbeat() {
        heartbeatWorkItem?.cancel()
        heartbeatWorkItem = nil
    }

    private func cancelPendingPing() {
        pingTimeoutWorkItem?.cancel()
        pingTimeoutWorkItem = nil
        pingToken = nil
        pingPurpose = nil
    }

    private func startStreaming() throws {
        guard let display, let transport else { throw SessionError.incompleteGate }
        let streamer = CaptureEncoder(
            displayID: display.displayID, transport: transport, bitrate: bitrate, audioEnabled: audioEnabled
        )
        streamer.onMetrics = { [weak self, weak streamerRef = streamer] metrics in
            guard let self, let streamerRef else { return }
            self.stateQueue.async {
                guard self.streamer === streamerRef else { return }
                Task { @MainActor in
                    self.onMetrics?(metrics)
                }
            }
        }
        streamer.onStopWithError = { [weak self, weak streamerRef = streamer] error in
            guard let self, let streamerRef else { return }
            self.stateQueue.async {
                guard self.streamer === streamerRef else { return }
                self.failed(error)
            }
        }
        self.streamer = streamer
        Task {
            do {
                try await streamer.start()
                stateQueue.async { [weak self, weak streamer] in
                    guard let self, let streamer, self.streamer === streamer else { return }
                    self.publish(.streaming)
                    self.scheduleHeartbeat()
                }
            } catch {
                stateQueue.async { [weak self] in
                    guard let self else { return }
                    guard self.streamer === streamer else { return }
                    self.failed(error)
                }
            }
        }
    }

    private func failed(_ error: Error) {
        if case StreamError.screenRecordingPermissionRequired = error {
            publish(.waitingForScreenRecordingPermission)
        } else {
            publish(.error(error.localizedDescription))
        }
        stopRuntime { [weak self] in
            guard let self else { return }
            stateQueue.async {
                guard !self.manuallyStopped else { return }
                self.publish(.disconnected)
                self.scheduleRetry()
            }
        }
    }

    private func scheduleRetry() {
        guard !manuallyStopped, retryWorkItem == nil else { return }
        publish(.retrying)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retryWorkItem = nil
            self.connect()
        }
        retryWorkItem = workItem
        stateQueue.asyncAfter(deadline: .now() + 2, execute: workItem)
    }

    private func cancelRetry() {
        retryWorkItem?.cancel()
        retryWorkItem = nil
    }

    private func stopRuntime(completion: (@Sendable () -> Void)? = nil) {
        if isRuntimeStopping {
            if let completion {
                stopCompletions.append(completion)
            }
            return
        }

        cancelHeartbeat()
        cancelPendingPing()

        let transport = self.transport
        self.transport = nil
        transport?.close()

        restartingEncoder = false
        receiverWaiting = false

        let displayToClose = self.display
        let streamerToClose = self.streamer

        guard streamerToClose != nil || displayToClose != nil else {
            completion?()
            return
        }

        isRuntimeStopping = true
        if let completion {
            stopCompletions.append(completion)
        }

        self.display = nil
        self.streamer = nil

        displayToClose?.close()

        if let streamerToClose {
            streamerToClose.stop()
        }

        self.stateQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.isRuntimeStopping = false
            let completions = self.stopCompletions
            self.stopCompletions.removeAll()
            completions.forEach { $0() }
        }
    }

    private func publish(_ status: HostStatus) {
        guard status != currentStatus else { return }
        currentStatus = status
        fputs("\(status.title)\n", stderr)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onStatus?(status)
            if status != .streaming {
                self.onMetrics?(SessionMetrics())
            }
        }
    }

    private func diagnostic(_ error: Error) -> Data {
        let json = ["message": error.localizedDescription]
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    }
}

private enum PingPurpose {
    case negotiation
    case heartbeat
    case recovery
}

enum SessionError: LocalizedError {
    case unsupportedPanel
    case incompleteGate
    case peer(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedPanel: "Tablet must report landscape 2960 x 1848 with a video/hevc decoder"
        case .incompleteGate: "Streaming attempted before compatibility gates completed"
        case .peer(let diagnostic): "Tablet error: \(diagnostic)"
        }
    }
}
