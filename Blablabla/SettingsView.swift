import SwiftUI
import AppKit
import Combine

struct SettingsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var updater: Updater
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
                .tabItem { Label("Status", systemImage: "waveform") }

            AboutTab(updater: updater)
                .tabItem { Label("About", systemImage: "info.circle") }
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
                .pickerStyle(.segmented)

                AdvisorNotice()
                STTStatusRow(coordinator: coordinator)
            } header: {
                Text("Cleanup")
            } footer: {
                Text(coordinator.cleanupMode.hint)
                    .font(.footnote).foregroundStyle(.secondary)
            }

            if coordinator.cleanupMode == .full {
                Section {
                    ModelRow(coordinator: coordinator)
                    ModelStatusRow(coordinator: coordinator)
                } header: {
                    Text("Model")
                } footer: {
                    Text(coordinator.llm.model.detail)
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("Hold to talk", selection: $hotkeyRaw) {
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

// MARK: - Hardware advisor

/// Speaks up only when the hardware is a reason to pick a lighter mode.
private struct AdvisorNotice: View {
    private let snapshot = SystemAdvisor.shared
    private var rec: SystemAdvisor.Recommendation { snapshot.recommendation }

    var body: some View {
        if rec.tone != .ok {
            Label {
                Text(rec.message)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: rec.tone == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .foregroundStyle(rec.tone == .warning ? .orange : .blue)
            }
            .font(.callout)
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

// MARK: - Model rows

/// Standard picker row; the model's state lives in `ModelStatusRow` below it.
private struct ModelRow: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        Picker("Model", selection: Binding(
            get: { coordinator.llm.model },
            set: { coordinator.selectModel($0) }
        )) {
            ForEach(LLMModel.allCases) { model in
                Text(model.label).tag(model)
            }
        }
        .pickerStyle(.menu)
    }
}

/// One line when idle/ready; a full-width progress bar while downloading.
private struct ModelStatusRow: View {
    @ObservedObject var coordinator: AppCoordinator

    private var llm: LLMService { coordinator.llm }

    var body: some View {
        switch llm.phase {
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Downloading…")
                    Spacer()
                    Text(downloadedText(progress))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            }

        case .failed(let msg):
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Status") {
                    HStack(spacing: 8) {
                        statusDot("Failed", color: .orange)
                        Button("Retry") { coordinator.ensureLLMLoaded() }
                            .controlSize(.small)
                    }
                }
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

        default:
            LabeledContent("Status") { compactStatus }
        }
    }

    @ViewBuilder
    private var compactStatus: some View {
        switch llm.phase {
        case .idle:
            let onDisk = ModelDownloader.isAvailableLocally(id: llm.model.repoId)
            Button(onDisk ? "Load" : "Download \(llm.model.formattedSize.replacingOccurrences(of: "~", with: ""))") {
                coordinator.ensureLLMLoaded()
            }
            .controlSize(.small)
        case .loading, .warming:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading…").foregroundStyle(.secondary)
            }
        case .ready:
            statusDot("Ready", color: .green)
        case .downloading, .failed:
            EmptyView()
        }
    }

    private func downloadedText(_ progress: Double) -> String {
        let total = llm.model.downloadGB
        return String(format: "%.1f of %.1f GB · %d%%", total * progress, total, Int(progress * 100))
    }

    private func statusDot(_ text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

// MARK: - LLM download source

/// Lets users behind a flaky or filtered route to huggingface.co point the
/// downloader at an API-compatible mirror. Takes effect on the next download
/// attempt (Retry).
private struct DownloadSourceRow: View {
    @AppStorage(ModelDownloader.hostKey) private var host = ""

    var body: some View {
        Section {
            TextField("Download from", text: $host, prompt: Text(ModelDownloader.defaultHost.absoluteString))
        } header: {
            Text("Advanced")
        } footer: {
            Text("Model download source. Leave empty for huggingface.co, or use a mirror with the same API (e.g. https://hf-mirror.com) if it's slow or blocked for you.")
                .font(.footnote).foregroundStyle(.secondary)
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

    private var isFull: Bool { coordinator.cleanupMode == .full }

    private var samplingIsDefault: Bool {
        temperature == LLMService.defaultTemperature
            && topP == LLMService.defaultTopP
            && repetitionPenalty == LLMService.defaultRepetitionPenalty
    }

    var body: some View {
        Form {
            if !isFull {
                Section {
                    HStack {
                        Label("These settings apply to Full mode.", systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Switch to Full") { coordinator.cleanupMode = .full }
                            .controlSize(.small)
                    }
                }
            }

            Group {
                Section {
                    TextEditor(text: $systemPrompt)
                        .font(.system(.callout, design: .monospaced))
                        .frame(minHeight: 150)
                        .scrollContentBackground(.hidden)
                } header: {
                    headerWithReset("Prompt", showReset: systemPrompt != LLMService.defaultSystemPrompt) {
                        systemPrompt = LLMService.defaultSystemPrompt
                    }
                } footer: {
                    Text("Sent with every cleanup, so shorter is faster.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section {
                    sliderRow("Temperature", value: $temperature, range: 0...1.5)
                    sliderRow("Top-P", value: $topP, range: 0.1...1.0)
                    sliderRow("Repetition penalty", value: $repetitionPenalty, range: 1.0...1.5)
                } header: {
                    headerWithReset("Sampling", showReset: !samplingIsDefault) {
                        temperature = LLMService.defaultTemperature
                        topP = LLMService.defaultTopP
                        repetitionPenalty = LLMService.defaultRepetitionPenalty
                    }
                } footer: {
                    Text("Lower temperature keeps the text closer to what you said.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .disabled(!isFull)

            DownloadSourceRow()
        }
        .formStyle(.grouped)
    }

    private func headerWithReset(_ title: String, showReset: Bool, reset: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            if showReset {
                Button("Reset", action: reset)
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 12) {
                Slider(value: value, in: range, step: 0.05)
                    .frame(maxWidth: 220)
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }
}

// MARK: - Status tab

private struct StatusTab: View {
    @ObservedObject var coordinator: AppCoordinator

    // Permissions can change in System Settings at any time; re-read them.
    @State private var micGranted = Permissions.microphoneGranted
    @State private var axGranted = Permissions.accessibilityGranted
    private let permissionTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Components") {
                componentRow("Speech recognition", detail: "Parakeet TDT v3 · Neural Engine",
                             state: sttState)
                if coordinator.cleanupMode == .full {
                    componentRow("Cleanup model", detail: "\(coordinator.llm.model.label) · 4-bit MLX",
                                 state: llmState)
                }
            }

            Section("Permissions") {
                permissionRow("Microphone", granted: micGranted, pane: "Privacy_Microphone")
                permissionRow("Accessibility", granted: axGranted, pane: "Privacy_Accessibility")
            }

            Section {
                MicLevelMeter(level: coordinator.audio.audioLevel,
                              recording: coordinator.isRecording)
            } header: {
                Text("Microphone")
            } footer: {
                Text("Hold the hotkey and speak. If the bars stay flat, check the input device in Sound Settings.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            if let ms = coordinator.lastLatencyMs {
                Section("Last dictation") {
                    LabeledContent("Latency") {
                        Text("\(ms) ms").font(.body.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    LabeledContent("Result") {
                        Text(coordinator.status).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(permissionTimer) { _ in
            micGranted = Permissions.microphoneGranted
            axGranted = Permissions.accessibilityGranted
        }
    }

    private func componentRow(_ title: String, detail: String, state: (String, Color)) -> some View {
        LabeledContent {
            statusDot(state.0, color: state.1)
        } label: {
            Text(title)
            Text(detail)
        }
    }

    private func permissionRow(_ title: String, granted: Bool, pane: String) -> some View {
        LabeledContent(title) {
            if granted {
                statusDot("Granted", color: .green)
            } else {
                HStack(spacing: 8) {
                    statusDot("Missing", color: .orange)
                    Button("Open Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func statusDot(_ text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).foregroundStyle(.secondary)
        }
    }

    private var sttState: (String, Color) {
        switch coordinator.stt.phase {
        case .idle: return ("Idle", .secondary)
        case .downloading(let p): return ("Downloading \(Int(p * 100))%", .blue)
        case .loading, .warming: return ("Loading", .blue)
        case .ready: return ("Ready", .green)
        case .failed: return ("Failed", .red)
        }
    }

    private var llmState: (String, Color) {
        switch coordinator.llm.phase {
        case .idle: return ("Not loaded", .secondary)
        case .downloading(let p): return ("Downloading \(Int(p * 100))%", .blue)
        case .loading, .warming: return ("Loading", .blue)
        case .ready: return ("Ready", .green)
        case .failed: return ("Failed", .red)
        }
    }
}

// MARK: - About tab

private struct AboutTab: View {
    @ObservedObject var updater: Updater

    private let repo = URL(string: "https://github.com/gpogrebnyack/Blablabla")!

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Blablabla").font(.title2.weight(.semibold))
                        Text(version).foregroundStyle(.secondary)
                        Text("Hold a key, talk, get clean text in any app.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.automaticallyChecksForUpdates = $0 }
                ))
                LabeledContent {
                    Button("Check for Updates…") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                } label: {
                    Text("Last checked")
                    Text(lastChecked)
                }
            } header: {
                Text("Updates")
            }

            Section {
                Link(destination: repo) { linkRow("Source code on GitHub", icon: "chevron.left.forwardslash.chevron.right") }
                Link(destination: repo.appendingPathComponent("releases")) { linkRow("Release notes", icon: "doc.text") }
                Link(destination: repo.appendingPathComponent("issues")) { linkRow("Report a problem", icon: "exclamationmark.bubble") }
            } footer: {
                Text("Speech: NVIDIA Parakeet via FluidAudio. Cleanup: Qwen / Gemma via Apple MLX. Updates: Sparkle. MIT License.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var lastChecked: String {
        guard let date = updater.lastUpdateCheckDate else { return "Never" }
        return date.formatted(.relative(presentation: .named))
    }

    private func linkRow(_ title: String, icon: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Image(systemName: "arrow.up.right").foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}
