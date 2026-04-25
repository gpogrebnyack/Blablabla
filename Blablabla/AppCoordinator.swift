import Foundation
import SwiftUI
import Combine
import OSLog

@MainActor
final class AppCoordinator: ObservableObject {
    @Published var isRecording = false
    @Published var status: String = "Idle"
    @Published var lastLatencyMs: Int?
    @Published var sttReady = false
    @Published var cleanupMode: CleanupMode = .fast {
        didSet {
            UserDefaults.standard.set(cleanupMode.rawValue, forKey: CleanupMode.storageKey)
            if cleanupMode == .full {
                ensureLLMLoaded()
            }
        }
    }

    let hotkey = HotkeyManager()
    let audio = AudioRecorder()
    let stt = STTService()
    let llm = LLMService()
    let inserter = Inserter()

    private let log = Logger(subsystem: "blablabla", category: "coord")
    private var releaseTimestamp: CFAbsoluteTime = 0
    private var capturedFocus: AXUIElement?
    private var llmPhaseObserver: AnyCancellable?
    private var sttPhaseObserver: AnyCancellable?
    private var audioObserver: AnyCancellable?

    init() {
        // Restore the mode from UserDefaults before any UI binds.
        if let raw = UserDefaults.standard.string(forKey: CleanupMode.storageKey),
           let mode = CleanupMode(rawValue: raw) {
            self.cleanupMode = mode
        }
        // Mirror downstream services' @Published changes onto our own
        // ObservableObject so SwiftUI views observing AppCoordinator update
        // when LLM/STT/audio state changes.
        llmPhaseObserver = llm.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
        sttPhaseObserver = stt.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
        audioObserver = audio.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
        Task { await bootstrap() }
    }

    func bootstrap() async {
        Permissions.requestAccessibility()
        await Permissions.requestMicrophone()

        // STT loads always — it's the floor of every pipeline.
        await warmSTT()
        // LLM only loads if the user has it enabled (or already on disk).
        if cleanupMode == .full {
            ensureLLMLoaded()
        }

        hotkey.onPress = { [weak self] in
            Task { @MainActor in await self?.startRecording() }
        }
        hotkey.onRelease = { [weak self] in
            Task { @MainActor in await self?.stopAndProcess() }
        }
        hotkey.installFromDefaults()
    }

    private func warmSTT() async {
        do {
            try await stt.load()
            sttReady = true
            log.info("STT ready")
        } catch {
            status = "STT load failed: \(error.localizedDescription)"
            log.error("STT load: \(error.localizedDescription)")
        }
    }

    /// Triggers a retry of STT loading (e.g. after transient network failure).
    func retrySTTLoad() {
        Task { await warmSTT() }
    }

    /// Kicks off LLM download/load if not already loaded. Errors surface via
    /// `llm.phase = .failed(...)`.
    func ensureLLMLoaded() {
        Task {
            do { try await llm.ensureLoaded().value }
            catch { log.error("LLM load failed: \(error.localizedDescription)") }
        }
    }

    func startRecording() async {
        guard !isRecording else { return }
        capturedFocus = inserter.captureFocus()
        do {
            try audio.start()
            isRecording = true
            status = "Recording…"
        } catch {
            status = "Mic error: \(error.localizedDescription)"
        }
    }

    func stopAndProcess() async {
        guard isRecording else { return }
        let samples = audio.stop()
        isRecording = false
        releaseTimestamp = CFAbsoluteTimeGetCurrent()
        status = "Transcribing…"

        guard !samples.isEmpty else { status = "Idle"; return }

        do {
            let raw = try await stt.transcribe(samples: samples)
            guard !raw.isEmpty else { status = "Idle"; return }

            switch cleanupMode {
            case .off:
                await streamInsert(raw, into: capturedFocus)
                finishPipeline(raw: raw, clean: raw, suffix: "off")

            case .fast:
                let cleaned = RegexCleaner.clean(raw)
                await streamInsert(cleaned, into: capturedFocus)
                finishPipeline(raw: raw, clean: cleaned, suffix: "regex")

            case .full:
                guard llm.isReady else {
                    log.info("LLM not ready (\(String(describing: self.llm.phase))) — degrading to regex")
                    let cleaned = RegexCleaner.clean(raw)
                    await streamInsert(cleaned, into: capturedFocus)
                    finishPipeline(raw: raw, clean: cleaned, suffix: "regex (LLM not ready)")
                    return
                }
                await runFullCleanupPipeline(raw: raw)
            }
        } catch {
            status = "Error: \(error.localizedDescription)"
            log.error("pipeline: \(error.localizedDescription)")
        }
    }

    /// Simulates the LLM-streaming look for already-known text: split into a
    /// few characters at a time with a tiny delay between AX writes so the
    /// target app renders incrementally instead of all-at-once.
    private func streamInsert(_ text: String, into focus: AXUIElement?) async {
        let session = inserter.beginStream(into: focus)
        let chunkSize = 4
        let delayNanos: UInt64 = 18_000_000  // 18 ms — ~220 chars/sec, comparable to LLM decode

        var idx = text.startIndex
        while idx < text.endIndex {
            let end = text.index(idx, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
            session.append(String(text[idx..<end]))
            idx = end
            await Task.yield()
            if idx < text.endIndex {
                try? await Task.sleep(nanoseconds: delayNanos)
            }
        }
        session.finish()
    }

    private func runFullCleanupPipeline(raw: String) async {
        // Skip LLM heuristic still applies — short/clean utterances don't benefit
        // from LLM and we save 500-1500ms of latency.
        if Self.shouldSkipLLM(raw) {
            await streamInsert(raw, into: capturedFocus)
            finishPipeline(raw: raw, clean: raw, suffix: "LLM skipped")
            return
        }

        status = "Cleaning…"
        let session = inserter.beginStream(into: capturedFocus)
        var aggregated = ""
        var chunkCount = 0
        let streamStart = CFAbsoluteTimeGetCurrent()
        do {
            for try await chunk in llm.cleanStream(rawText: raw) {
                chunkCount += 1
                let dt = Int((CFAbsoluteTimeGetCurrent() - streamStart) * 1000)
                log.debug("chunk #\(chunkCount) @+\(dt)ms (\(chunk.count) chars)")
                session.append(chunk)
                aggregated += chunk
                await Task.yield()
            }
            session.finish()
        } catch {
            log.error("LLM stream error: \(error.localizedDescription)")
            if aggregated.isEmpty {
                // Nothing yet — discard the failed AX session and stream raw with the same effect.
                await streamInsert(raw, into: capturedFocus)
            } else {
                session.finish()
            }
        }
        finishPipeline(raw: raw, clean: aggregated, suffix: "LLM")
    }

    private func finishPipeline(raw: String, clean: String, suffix: String) {
        let dt = Int((CFAbsoluteTimeGetCurrent() - releaseTimestamp) * 1000)
        lastLatencyMs = dt
        status = "Idle (\(dt) ms, \(suffix))"
        log.info("Pipeline \(dt) ms (\(suffix)) — raw=\"\(raw, privacy: .private)\" clean=\"\(clean, privacy: .private)\"")
    }

    /// Heuristic: is this utterance worth running through the LLM?
    /// Returns true (skip LLM) when:
    /// - the text is one or two words (LLM has nothing to remove)
    /// - the text is ≤30 chars AND doesn't start with a known filler ("так", "ну", "вот", etc.)
    /// Otherwise returns false (run LLM).
    static func shouldSkipLLM(_ rawText: String) -> Bool {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }

        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
        if words.count <= 2 { return true }

        guard trimmed.count <= 30 else { return false }

        // Lowercase for prefix matching; remove leading punctuation/quotes the
        // tokenizer may have inserted.
        let lower = trimmed.lowercased()
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        let fillerStarts = [
            "ну ", "ну,", "вот ", "вот,",
            "так ", "так,", "значит ", "значит,",
            "короче", "типа ", "типа,",
            "в общем", "эм", "э-э", "м-м", "ага", "ой,",
        ]
        for start in fillerStarts where lower.hasPrefix(start) { return false }
        return true
    }
}

struct MenuBarContent: View {
    @ObservedObject var coordinator: AppCoordinator

    static func llmStateLabel(_ phase: LLMService.Phase) -> String {
        switch phase {
        case .idle: return "idle"
        case .downloading(let p): return "downloading \(Int(p * 100))%"
        case .loading: return "loading…"
        case .warming: return "warming…"
        case .ready: return "ready"
        case .failed(let s): return "failed (\(s))"
        }
    }

    var body: some View {
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Divider()
        Button("Quit Blablabla") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
