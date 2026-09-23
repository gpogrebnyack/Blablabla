import Foundation
import Combine
import OSLog
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

@MainActor
final class LLMService: ObservableObject {
    private var container: ModelContainer?
    private var loadTask: Task<Void, Error>?
    private let log = Logger(subsystem: "blablabla", category: "llm")
    @Published private(set) var model: LLMModel = .stored

    /// Coarse load state for UI. `progress` is 0..1 during a download; `nil`
    /// means we're not currently moving bytes.
    enum Phase: Equatable {
        case idle
        case downloading(Double)
        case loading
        case warming
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    /// Compact prompt — every system token is paid on every clean() call as prefill.
    static let defaultSystemPrompt = """
    Твоя задача — очистить текст от мусора, слов-паразитов, заиканий и ошибок. Расставь пунктуацию и сохрани единообразие терминов.

    ПРАВИЛО: Сохрани оригинальную форму глаголов и местоимений. Если в исходнике написано «ты», «тебе», «сделай» — в готовом тексте тоже должны быть «ты», «тебе», «сделай».

    Выведи ТОЛЬКО готовый текст без комментариев.
    """

    static let systemPromptKey = "blabla.llm.systemPrompt"
    static let temperatureKey = "blabla.llm.temperature"
    static let topPKey = "blabla.llm.topP"
    static let repetitionPenaltyKey = "blabla.llm.repetitionPenalty"

    static let defaultTemperature: Double = 0.7
    static let defaultTopP: Double = 0.8
    static let defaultRepetitionPenalty: Double = 1.1

    var systemPrompt: String {
        UserDefaults.standard.string(forKey: Self.systemPromptKey) ?? Self.defaultSystemPrompt
    }

    /// Sampling values, exposed so the cloud engine can mirror them.
    var temperature: Double { readDouble(Self.temperatureKey, default: Self.defaultTemperature) }
    var topP: Double { readDouble(Self.topPKey, default: Self.defaultTopP) }

    private func readDouble(_ key: String, default fallback: Double) -> Double {
        let v = UserDefaults.standard.double(forKey: key)
        return v == 0 ? fallback : v
    }

    var isReady: Bool {
        if case .ready = phase { return true }
        return false
    }

    /// Idempotent loader. Calling it multiple times shares one underlying download/init.
    @discardableResult
    func ensureLoaded() -> Task<Void, Error> {
        if let t = loadTask { return t }
        let t = Task { try await self.load() }
        loadTask = t
        return t
    }

    /// Switches to another model: drops the loaded one (and any in-flight
    /// download) and returns to `.idle`. Call `ensureLoaded()` to load it.
    func select(_ newModel: LLMModel) {
        guard newModel != model else { return }
        model = newModel
        UserDefaults.standard.set(newModel.rawValue, forKey: LLMModel.storageKey)
        loadTask?.cancel()
        loadTask = nil
        container = nil
        phase = .idle
    }

    private func load() async throws {
        if isReady { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        let target = model
        let modelId = target.repoId
        phase = .downloading(0)
        let cfg = ModelConfiguration(id: modelId)
        let downloader = ModelDownloader(host: ModelDownloader.configuredHost)
        if ModelDownloader.isAvailableLocally(id: modelId) { phase = .loading }

        let cont: ModelContainer
        do {
            cont = try await loadModelContainer(
                from: downloader,
                using: #huggingFaceTokenizerLoader(),
                configuration: cfg,
                progressHandler: { @Sendable progress in
                    let frac = progress.fractionCompleted
                    Task { @MainActor [weak self] in
                        guard let self, self.model == target else { return }
                        if case .downloading(let cur) = self.phase, frac > cur {
                            self.phase = .downloading(frac)
                        }
                        if frac >= 1 { self.phase = .loading }
                    }
                }
            )
        } catch {
            // Superseded by select(): the new model owns phase/loadTask now.
            guard model == target else { throw error }
            let diagnostics = Self.diagnostics(for: error)
            phase = .failed(diagnostics.summary)
            log.error("LLM download/load failed: \(diagnostics.logMessage, privacy: .public)")
            loadTask = nil
            throw error
        }
        guard model == target else { throw CancellationError() }
        self.container = cont
        phase = .warming

        do {
            try await cont.perform { context in
                let input = try await context.processor.prepare(input: UserInput(prompt: "."))
                let stream = try MLXLMCommon.generate(
                    input: input,
                    parameters: GenerateParameters(maxTokens: 1, temperature: 0),
                    context: context
                )
                for await _ in stream { break }
            }
        } catch {
            guard model == target else { throw error }
            let diagnostics = Self.diagnostics(for: error)
            phase = .failed(diagnostics.summary)
            log.error("LLM warmup failed: \(diagnostics.logMessage, privacy: .public)")
            container = nil
            loadTask = nil
            throw error
        }

        guard model == target else { throw CancellationError() }
        phase = .ready
        log.info("\(target.label, privacy: .public) ready in \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)) ms")
    }

    private static func diagnostics(for error: Error) -> (summary: String, logMessage: String) {
        let nsError = error as NSError
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        let failingURL = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL

        var summary = error.localizedDescription
        summary += " [\(nsError.domain):\(nsError.code)]"

        var parts = [
            "summary=\"\(summary)\"",
            "domain=\(nsError.domain)",
            "code=\(nsError.code)",
        ]

        if let failingURL {
            parts.append("url=\(failingURL.absoluteString)")
        }

        if let underlying {
            parts.append("underlying=\(underlying.domain):\(underlying.code) \"\(underlying.localizedDescription)\"")
        }

        if !nsError.userInfo.isEmpty {
            parts.append("userInfo=\(String(describing: nsError.userInfo))")
        }

        return (summary, parts.joined(separator: " | "))
    }

    private func makeParams(rawText: String) -> GenerateParameters {
        let cap = min(512, max(48, rawText.count + 32))
        let temperature = Float(readDouble(Self.temperatureKey, default: Self.defaultTemperature))
        let topP = Float(readDouble(Self.topPKey, default: Self.defaultTopP))
        let repetitionPenalty = Float(readDouble(Self.repetitionPenaltyKey, default: Self.defaultRepetitionPenalty))
        return GenerateParameters(
            maxTokens: cap,
            temperature: temperature,
            topP: topP,
            repetitionPenalty: repetitionPenalty,
            repetitionContextSize: 32,
            prefillStepSize: 1024
        )
    }

    /// Streams cleaned text chunks as the model generates them. <think>…</think>
    /// blocks are filtered on the fly (with a small lookahead so partial tags don't leak).
    func cleanStream(rawText: String) -> AsyncThrowingStream<String, Error> {
        let prompt = systemPrompt
        let params = makeParams(rawText: rawText)
        let cont = container

        return AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                guard let cont else {
                    continuation.finish(throwing: NSError(
                        domain: "blabla.llm", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "LLM not loaded"]))
                    return
                }
                do {
                    try await cont.perform { context in
                        let chat: [Chat.Message] = [.system(prompt), .user(rawText)]
                        let userInput = UserInput(
                            chat: chat,
                            additionalContext: ["enable_thinking": false]
                        )
                        let input = try await context.processor.prepare(input: userInput)
                        let modelStream = try MLXLMCommon.generate(
                            input: input, parameters: params, context: context)

                        var stripper = ThinkStripper()
                        for await event in modelStream {
                            if Task.isCancelled { break }
                            if case .chunk(let s) = event {
                                let safe = stripper.process(s)
                                if !safe.isEmpty { continuation.yield(safe) }
                            }
                        }
                        let tail = stripper.flush()
                        if !tail.isEmpty { continuation.yield(tail) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Incrementally strips Qwen3 `<think>…</think>` blocks from a token stream.
/// Holds back up to (tagLen-1) chars at a time so partial tags split across
/// chunks aren't accidentally emitted.
nonisolated private struct ThinkStripper {
    private var inside = false
    private var buf = ""
    private static let openTag = "<think>"
    private static let closeTag = "</think>"

    /// Process a chunk; return the portion that's safe to emit now.
    mutating func process(_ chunk: String) -> String {
        buf += chunk
        var out = ""
        loop: while !buf.isEmpty {
            if inside {
                if let r = buf.range(of: Self.closeTag) {
                    buf.removeSubrange(buf.startIndex..<r.upperBound)
                    inside = false
                } else {
                    // Drop everything except a possible partial close-tag tail.
                    let keep = min(buf.count, Self.closeTag.count - 1)
                    buf = String(buf.suffix(keep))
                    break loop
                }
            } else {
                if let r = buf.range(of: Self.openTag) {
                    out += buf[buf.startIndex..<r.lowerBound]
                    buf.removeSubrange(buf.startIndex..<r.upperBound)
                    inside = true
                } else {
                    // Emit everything except the last (openTagLen-1) chars in case
                    // they're the start of an upcoming `<think>`.
                    let keep = min(buf.count, Self.openTag.count - 1)
                    let emitCount = buf.count - keep
                    if emitCount > 0 {
                        let idx = buf.index(buf.startIndex, offsetBy: emitCount)
                        out += buf[buf.startIndex..<idx]
                        buf.removeSubrange(buf.startIndex..<idx)
                    }
                    break loop
                }
            }
        }
        return out
    }

    /// Final flush — call when the model stream ends.
    mutating func flush() -> String {
        if inside { return "" }  // unclosed think block — drop everything held
        let out = buf
        buf = ""
        return out
    }
}
