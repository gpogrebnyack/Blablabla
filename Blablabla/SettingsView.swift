import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @AppStorage(LLMService.systemPromptKey) private var systemPrompt: String = LLMService.defaultSystemPrompt
    @AppStorage(LLMService.temperatureKey) private var temperature: Double = LLMService.defaultTemperature
    @AppStorage(LLMService.topPKey) private var topP: Double = LLMService.defaultTopP
    @AppStorage(LLMService.repetitionPenaltyKey) private var repetitionPenalty: Double = LLMService.defaultRepetitionPenalty
    @AppStorage(HotkeyManager.kModifierFlagDefaultsKey) private var hotkeyRaw: Int = Int(NSEvent.ModifierFlags.option.rawValue)

    var body: some View {
        TabView {
            GeneralTab(coordinator: coordinator, hotkeyRaw: $hotkeyRaw)
                .tabItem { Label("General", systemImage: "slider.horizontal.3") }

            CleanupTab(coordinator: coordinator,
                       systemPrompt: $systemPrompt,
                       temperature: $temperature,
                       topP: $topP,
                       repetitionPenalty: $repetitionPenalty)
                .tabItem { Label("Cleanup", systemImage: "sparkles") }

            StatusTab(coordinator: coordinator)
                .tabItem { Label("Status", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 460)
        .scenePadding()
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var coordinator: AppCoordinator
    @Binding var hotkeyRaw: Int

    var body: some View {
        Form {
            Section {
                Picker("Mode", selection: Binding(
                    get: { coordinator.cleanupMode },
                    set: { coordinator.cleanupMode = $0 }
                )) {
                    ForEach(CleanupMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                LabeledContent("About this mode") {
                    Text(coordinator.cleanupMode.hint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }

                AdvisorCard(currentMode: coordinator.cleanupMode)

                STTStatusRow(coordinator: coordinator)

                if coordinator.cleanupMode == .full {
                    LLMStatusRow(coordinator: coordinator)
                }
            } header: {
                Text("Cleanup")
            } footer: {
                Text("Choose how aggressively to polish recognized text.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                Picker("Modifier", selection: $hotkeyRaw) {
                    Text("⌥  Right Option").tag(Int(NSEvent.ModifierFlags.option.rawValue))
                    Text("⌃  Control").tag(Int(NSEvent.ModifierFlags.control.rawValue))
                    Text("⌘  Command").tag(Int(NSEvent.ModifierFlags.command.rawValue))
                    Text("fn  Globe").tag(Int(NSEvent.ModifierFlags.function.rawValue))
                }
                .onChange(of: hotkeyRaw) { _, newValue in
                    coordinator.hotkey.install(modifier: NSEvent.ModifierFlags(rawValue: UInt(newValue)))
                }
            } header: {
                Text("Hotkey")
            } footer: {
                Text("Hold the chosen key to record. Release to transcribe and insert.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Hardware advisor card

private struct AdvisorCard: View {
    let currentMode: CleanupMode
    private let snapshot = SystemAdvisor.shared
    private var rec: SystemAdvisor.Recommendation { snapshot.recommendation }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(toneColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(snapshot.chipName).font(.callout.weight(.medium))
                    Text("·").foregroundStyle(.tertiary)
                    Text(snapshot.formattedRAM).font(.callout).foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Text(snapshot.formattedDisk).font(.callout).foregroundStyle(.secondary)
                }
                Text(rec.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if currentMode != rec.mode {
                    Text("Recommended: **\(rec.mode.label)**")
                        .font(.callout)
                        .foregroundStyle(toneColor)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(toneColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(toneColor.opacity(0.25), lineWidth: 0.5)
        )
    }

    private var icon: String {
        switch rec.tone {
        case .ok:      return "checkmark.seal.fill"
        case .info:    return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }

    private var toneColor: Color {
        switch rec.tone {
        case .ok:      return .green
        case .info:    return .blue
        case .warning: return .orange
        }
    }
}

// MARK: - Mic level meter

private struct MicLevelMeter: View {
    let level: Float
    let recording: Bool

    private let barCount = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 3) {
                ForEach(0..<barCount, id: \.self) { i in
                    let threshold = Float(i + 1) / Float(barCount)
                    let active = level >= threshold * 0.9
                    RoundedRectangle(cornerRadius: 2)
                        .fill(active ? barColor(for: i) : Color.secondary.opacity(0.15))
                        .frame(height: 18)
                }
            }
            HStack {
                if recording {
                    Image(systemName: "mic.fill").foregroundStyle(.red)
                    Text("Recording — \(Int(level * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "mic.slash").foregroundStyle(.secondary)
                    Text("Idle. Hold the hotkey to test.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Sound Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.sound?input") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private func barColor(for index: Int) -> Color {
        let t = Float(index) / Float(barCount - 1)
        if t < 0.6 { return .green }
        if t < 0.85 { return .yellow }
        return .red
    }
}

// MARK: - STT status row

private struct STTStatusRow: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        switch coordinator.stt.phase {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading speech recognition…").foregroundStyle(.secondary)
            }
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Downloading Parakeet TDT v3 (~2.3 GB)").font(.callout)
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: progress).progressViewStyle(.linear)
            }
        case .warming:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Warming up speech recognition…").foregroundStyle(.secondary)
            }
        case .ready:
            EmptyView()  // hide once ready — no need to clutter
        case .failed(let msg):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Speech recognition failed to load").bold()
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Retry") { coordinator.retrySTTLoad() }
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - LLM status row

private struct LLMStatusRow: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        switch coordinator.llm.phase {
        case .idle:
            LabeledContent("Model") {
                Button("Download Qwen3.5-4B (~2.4 GB)") {
                    coordinator.ensureLLMLoaded()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Downloading model").font(.callout)
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            }

        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading model into memory…").foregroundStyle(.secondary)
            }

        case .warming:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Warming up…").foregroundStyle(.secondary)
            }

        case .ready:
            Label {
                Text("LLM ready")
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

        case .failed(let msg):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Load failed").bold()
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Retry") { coordinator.ensureLLMLoaded() }
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - Cleanup tab (prompt + sampling, only meaningful in Full mode)

private struct CleanupTab: View {
    @ObservedObject var coordinator: AppCoordinator
    @Binding var systemPrompt: String
    @Binding var temperature: Double
    @Binding var topP: Double
    @Binding var repetitionPenalty: Double

    var body: some View {
        Form {
            if coordinator.cleanupMode != .full {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text("These settings apply only in Full mode. Switch to Full in General to enable.")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                TextEditor(text: $systemPrompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 160)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                    )

                HStack {
                    Spacer()
                    Button("Reset to default") {
                        systemPrompt = LLMService.defaultSystemPrompt
                    }
                    .controlSize(.small)
                }
            } header: {
                Text("System prompt")
            } footer: {
                Text("Each token here is paid as prefill on every cleanup. Keep it tight.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Temperature") {
                    sliderRow(value: $temperature, range: 0...1.5, step: 0.05)
                }
                LabeledContent("Top-P") {
                    sliderRow(value: $topP, range: 0.1...1.0, step: 0.05)
                }
                LabeledContent("Repetition penalty") {
                    sliderRow(value: $repetitionPenalty, range: 1.0...1.5, step: 0.05)
                }
                HStack {
                    Spacer()
                    Button("Reset to defaults") {
                        temperature = LLMService.defaultTemperature
                        topP = LLMService.defaultTopP
                        repetitionPenalty = LLMService.defaultRepetitionPenalty
                    }
                    .controlSize(.small)
                }
            } header: {
                Text("Sampling")
            } footer: {
                Text("Lower temperature ⇒ more conservative; higher ⇒ more creative.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(coordinator.cleanupMode != .full)
    }

    @ViewBuilder
    private func sliderRow(value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        HStack(spacing: 12) {
            Slider(value: value, in: range, step: step)
                .frame(maxWidth: 240)
            Text(String(format: "%.2f", value.wrappedValue))
                .font(.body.monospacedDigit())
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Status tab

private struct StatusTab: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        Form {
            Section("Models") {
                LabeledContent("Speech-to-text") {
                    statusBadge(text: sttBadgeText, color: sttColor)
                }
                LabeledContent("Detail") {
                    Text("Parakeet TDT v3 (FluidAudio, ANE)").foregroundStyle(.secondary)
                }
                if coordinator.cleanupMode == .full {
                    LabeledContent("LLM") {
                        statusBadge(text: MenuBarContent.llmStateLabel(coordinator.llm.phase).capitalized,
                                    color: llmColor(coordinator.llm.phase))
                    }
                    LabeledContent("Detail") {
                        Text("Qwen3.5 4B 4-bit (MLX)").foregroundStyle(.secondary)
                    }
                }
            }

            Section("Permissions") {
                LabeledContent("Microphone") {
                    HStack(spacing: 8) {
                        statusBadge(text: Permissions.microphoneGranted ? "Granted" : "Missing",
                                    color: Permissions.microphoneGranted ? .green : .orange)
                        if !Permissions.microphoneGranted {
                            Button("Open Settings…") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                }
                LabeledContent("Accessibility") {
                    HStack(spacing: 8) {
                        statusBadge(text: Permissions.accessibilityGranted ? "Granted" : "Missing",
                                    color: Permissions.accessibilityGranted ? .green : .orange)
                        if !Permissions.accessibilityGranted {
                            Button("Open Settings…") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            Section {
                MicLevelMeter(level: coordinator.audio.audioLevel,
                              recording: coordinator.isRecording)
            } header: {
                Text("Microphone level")
            } footer: {
                Text("Hold the hotkey and speak — bars should fill. If the meter stays flat while you talk, your mic is muted, on the wrong device, or your input level is too low. Open Sound Settings to adjust.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Last run") {
                LabeledContent("Status") {
                    Text(coordinator.status).foregroundStyle(.secondary)
                }
                if let ms = coordinator.lastLatencyMs {
                    LabeledContent("Latency") {
                        Text("\(ms) ms").font(.body.monospacedDigit())
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func statusBadge(text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).foregroundStyle(.primary)
        }
    }

    private func llmColor(_ phase: LLMService.Phase) -> Color {
        switch phase {
        case .ready: return .green
        case .failed: return .red
        case .downloading, .loading, .warming: return .blue
        case .idle: return .secondary
        }
    }

    private var sttBadgeText: String {
        switch coordinator.stt.phase {
        case .idle: return "Idle"
        case .downloading(let p): return "Downloading \(Int(p * 100))%"
        case .loading: return "Loading"
        case .warming: return "Warming"
        case .ready: return "Ready"
        case .failed: return "Failed"
        }
    }

    private var sttColor: Color {
        switch coordinator.stt.phase {
        case .ready: return .green
        case .failed: return .red
        case .downloading, .loading, .warming: return .blue
        case .idle: return .secondary
        }
    }
}
