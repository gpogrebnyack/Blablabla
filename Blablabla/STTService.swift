import Foundation
import Combine
import OSLog
import FluidAudio

@MainActor
final class STTService: ObservableObject {
    enum Phase: Equatable {
        case idle
        case downloading(Double)   // 0…1
        case loading
        case warming
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    private var asrManager: AsrManager?
    private var pollTask: Task<Void, Never>?
    private let log = Logger(subsystem: "blablabla", category: "stt")

    /// Approx total disk size of Parakeet TDT v3, used as denominator for the
    /// poll-based progress fallback when FluidAudio doesn't surface it.
    private static let parakeetExpectedBytes: Int64 = 2_300_000_000

    private static var parakeetCacheDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first!
        return appSupport.appendingPathComponent("FluidAudio/Models/parakeet-tdt-0.6b-v3",
                                                 isDirectory: true)
    }

    func load() async throws {
        let t0 = CFAbsoluteTimeGetCurrent()

        // If models aren't on disk yet, surface a Downloading phase backed by
        // a directory-size poll. FluidAudio doesn't give us a callback hook,
        // so this is the most honest signal we can show.
        let cacheDir = Self.parakeetCacheDir
        let alreadyOnDisk = directorySize(cacheDir) > 1_500_000_000  // some files there
        if !alreadyOnDisk {
            phase = .downloading(0)
            startDiskPolling(at: cacheDir, expectedBytes: Self.parakeetExpectedBytes)
        } else {
            phase = .loading
        }

        do {
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            stopDiskPolling()
            phase = .loading
            let manager = AsrManager(models: models)
            self.asrManager = manager

            phase = .warming
            // Warmup with 0.5 s of silence at 16 kHz.
            var state = TdtDecoderState.make()
            let silence = [Float](repeating: 0, count: 8_000)
            _ = try? await manager.transcribe(silence, decoderState: &state)
        } catch {
            stopDiskPolling()
            phase = .failed(error.localizedDescription)
            throw error
        }

        phase = .ready
        log.info("STT ready in \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)) ms")
    }

    func transcribe(samples: [Float]) async throws -> String {
        guard let asrManager else {
            throw NSError(domain: "blabla.stt", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "STT not loaded"])
        }
        var state = TdtDecoderState.make()
        let result = try await asrManager.transcribe(samples, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Polling

    private func startDiskPolling(at dir: URL, expectedBytes: Int64) {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self else { return }
                if case .ready = self.phase { return }
                let bytes = self.directorySize(dir)
                let frac = max(0, min(1, Double(bytes) / Double(expectedBytes)))
                if case .downloading = self.phase {
                    self.phase = .downloading(frac)
                }
            }
        }
    }

    private func stopDiskPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func directorySize(_ url: URL) -> Int64 {
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
}
