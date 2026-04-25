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
    private var pollTask: Task<Void, Never>?
    private let log = Logger(subsystem: "blablabla", category: "llm")
    private let modelId = "mlx-community/Qwen3.5-4B-MLX-4bit"

    /// Approx download size for Qwen3.5-4B-MLX-4bit (used by disk poll).
    private static let qwenExpectedBytes: Int64 = 2_400_000_000

    private var modelCacheDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory,
                                            in: .userDomainMask).first!
        return docs.appendingPathComponent("huggingface/models/\(modelId)",
                                           isDirectory: true)
    }

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
    /// One example is enough for Qwen3.5-4B; more examples slowed prefill by ~3× without
    /// noticeable quality gain in our benchmark.
    static let defaultSystemPrompt = """
    Чисти русскую устную речь. Удаляй слова-паразиты: ну, вот, как бы, короче, типа, в общем, так, значит, эм, э-э, м-м, ага, ой. Не удаляй "вот"/"это" если нужны по смыслу. Исправь очевидные ошибки распознавания. Сохрани смысл и порядок слов, не перефразируй и ничего не добавляй. Верни ТОЛЬКО исправленный текст одной строкой, без кавычек.

    Примеры:
    Вход: Так ну а теперь давай потестируем нейросеть. В общем как она справляется с этими словами паразитами
    Выход: А теперь давай потестируем нейросеть. Как она справляется с этими словами-паразитами

    Вход: Короче, в общем, надо запушить ветку в гит и открыть пулл реквест
    Выход: Надо запушить ветку в гит и открыть пулл реквест
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

    private func load() async throws {
        if isReady { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        phase = .downloading(0)
        let cfg = ModelConfiguration(id: modelId)

        // Disk-size poll runs alongside the macro callback. Whichever reports
        // higher fraction wins — the HF callback is unreliable on small files.
        startDiskPolling()

        let cont: ModelContainer
        do {
            cont = try await #huggingFaceLoadModelContainer(
                configuration: cfg,
                progressHandler: { @Sendable progress in
                    let frac = progress.fractionCompleted
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if case .downloading(let cur) = self.phase, frac > cur {
                            self.phase = .downloading(frac)
                        }
                    }
                }
            )
        } catch {
            stopDiskPolling()
            phase = .failed(error.localizedDescription)
            loadTask = nil
            throw error
        }
        stopDiskPolling()
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
            phase = .failed(error.localizedDescription)
            throw error
        }

        phase = .ready
        log.info("LLM ready in \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)) ms")
    }

    private func startDiskPolling() {
        let dir = modelCacheDir
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self else { return }
                guard case .downloading = self.phase else { return }
                let bytes = Self.directorySize(dir)
                let frac = max(0, min(1, Double(bytes) / Double(Self.qwenExpectedBytes)))
                if case .downloading(let cur) = self.phase, frac > cur {
                    self.phase = .downloading(frac)
                }
            }
        }
    }

    private func stopDiskPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let v = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true {
                total += Int64(v?.fileSize ?? 0)
            }
        }
        return total
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
