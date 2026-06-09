import SwiftUI
import Observation

@Observable
@MainActor
final class SessionViewModel {
    var status: HostStatus = .disconnected
    var metrics = SessionMetrics()
    var bitrateMbps: Double = 12.0
    var audioEnabled = true

    var onResume: (() -> Void)?
    var onStop: (() -> Void)?
    var onQuit: (() -> Void)?
    var onBitrateChange: ((Int) -> Void)?
    var onAudioToggle: ((Bool) -> Void)?
}

struct PopoverView: View {
    @Bindable var viewModel: SessionViewModel
    @State private var isPulsing = false

    var body: some View {
        VStack(spacing: 16) {
            // Header: Status Card
            statusCard

            // Metrics Section (Only show details when relevant, or show zeroed metrics beautifully)
            metricsSection

            // Bitrate Slider Section
            bitrateSection

            // Audio Section
            audioSection

            Divider()
                .opacity(0.3)

            // Action Control Buttons
            controlsSection
        }
        .padding(16)
        .frame(width: 320)
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .withinWindow, state: .active)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: - Status Card
    private var statusCard: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
                .shadow(color: statusColor.opacity(0.6), radius: 6, x: 0, y: 0)
                .scaleEffect(isPulsing ? 1.2 : 0.9)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                        isPulsing = true
                    }
                }
                .onChange(of: viewModel.status) {
                    isPulsing = shouldPulse(viewModel.status)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text("Andmon Submonitor")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(statusText)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.primary)
            }

            Spacer()

            if isStreaming {
                Image(systemSymbolName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.green)
            } else if isNegotiating {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Metrics Section
    private var metricsSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                metricCard(
                    title: "Capture / Encode",
                    value: "\(viewModel.metrics.capturedFPS) / \(viewModel.metrics.encodedFPS) FPS",
                    icon: "display.2",
                    color: .blue
                )
                metricCard(
                    title: "Encode Latency",
                    value: String(format: "%.1f ms (max: %.1f)", viewModel.metrics.encodeLatencyAvgMs, viewModel.metrics.encodeLatencyMaxMs),
                    icon: "clock",
                    color: .purple
                )
            }

            HStack(spacing: 8) {
                metricCard(
                    title: "Buffer Size",
                    value: formatBytes(viewModel.metrics.usbQueueBytes),
                    icon: "tray.and.arrow.up",
                    color: .orange
                )
                metricCard(
                    title: "Dropped Frames",
                    value: "\(viewModel.metrics.usbVideoDrops + viewModel.metrics.encoderInputDrops)",
                    icon: "exclamationmark.triangle",
                    color: .red
                )
            }
        }
    }

    private func metricCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemSymbolName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }

    // MARK: - Bitrate Section
    private var bitrateSection: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Streaming Bitrate")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(Int(viewModel.bitrateMbps)) Mbps")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.blue)
            }

            Slider(
                value: $viewModel.bitrateMbps,
                in: 10...100,
                step: 1.0,
                onEditingChanged: { editing in
                    if !editing {
                        viewModel.onBitrateChange?(Int(viewModel.bitrateMbps * 1_000_000))
                    }
                }
            )
            .tint(.blue)

            HStack {
                Text("10M")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("100M")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, -4)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Audio Section
    private var audioSection: some View {
        Toggle(isOn: Binding(
            get: { viewModel.audioEnabled },
            set: { newValue in
                viewModel.audioEnabled = newValue
                viewModel.onAudioToggle?(newValue)
            }
        )) {
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.blue)
                Text("Stream Audio")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
            }
        }
        .toggleStyle(.switch)
        .padding(.horizontal, 4)
    }

    // MARK: - Controls Section
    private var controlsSection: some View {
        HStack(spacing: 8) {
            // Resume / Stop Button
            if showResumeButton {
                Button(action: { viewModel.onResume?() }) {
                    HStack {
                        Image(systemSymbolName: "play.fill")
                        Text("Resume")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .controlSize(.large)
            } else {
                Button(action: { viewModel.onStop?() }) {
                    HStack {
                        Image(systemSymbolName: "stop.fill")
                        Text("Stop")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .controlSize(.large)
            }

            // Quit Button
            Button(action: { viewModel.onQuit?() }) {
                Image(systemSymbolName: "power")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help("Quit Andmon")
        }
    }

    // MARK: - Helper Computations
    private var statusText: String {
        switch viewModel.status {
        case .disconnected: return "Disconnected"
        case .negotiating: return "Negotiating..."
        case .retrying: return "Retrying Shortly..."
        case .waitingForScreenRecordingPermission: return "Permission Required"
        case .streaming: return "Streaming Active"
        case .stopped: return "Stopped"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    private var statusColor: Color {
        switch viewModel.status {
        case .disconnected: return .gray
        case .stopped: return .gray
        case .negotiating, .retrying: return .orange
        case .waitingForScreenRecordingPermission: return .amber
        case .streaming: return .green
        case .error: return .red
        }
    }

    private var isStreaming: Bool {
        if case .streaming = viewModel.status { return true }
        return false
    }

    private var isNegotiating: Bool {
        switch viewModel.status {
        case .negotiating, .retrying: return true
        default: return false
        }
    }

    private var showResumeButton: Bool {
        switch viewModel.status {
        case .disconnected, .stopped, .error: return true
        default: return false
        }
    }

    private func shouldPulse(_ status: HostStatus) -> Bool {
        switch status {
        case .negotiating, .retrying: return true
        default: return false
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        } else {
            return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
        }
    }
}

// Support pre-macOS 15 SF Symbols if any (using fallback system symbol names)
extension Image {
    init(systemSymbolName name: String) {
        self.init(systemName: name)
    }
}

// Standard amber color support for Color
extension Color {
    static var amber: Color {
        Color(nsColor: NSColor.systemOrange) // systemOrange is closest on macOS
    }
}
