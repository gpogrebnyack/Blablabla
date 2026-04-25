import Foundation
import Combine
@preconcurrency import AVFoundation
import OSLog

@MainActor
final class AudioRecorder: ObservableObject {
    /// Peak amplitude of the last 50 ms of audio, range 0…1. Drives the VU
    /// meter in Settings so users can verify their mic is actually capturing.
    @Published var audioLevel: Float = 0

    private let engine = AVAudioEngine()
    private let buffer = SampleBuffer()
    private let log = Logger(subsystem: "blablabla", category: "audio")
    private var levelTimer: Timer?

    static let targetSampleRate: Double = 16_000

    func start() throws {
        buffer.reset()
        audioLevel = 0
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        )!
        guard let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw NSError(domain: "blabla.audio", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create audio converter"])
        }
        let buf = self.buffer

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { pcm, _ in
            Self.process(pcm: pcm, converter: converter, target: target, sink: buf)
        }
        try engine.start()

        // 20 Hz polling for the live mic-level meter.
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            let peak = self.buffer.takePeak()
            Task { @MainActor in self.audioLevel = peak }
        }
    }

    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        levelTimer?.invalidate()
        levelTimer = nil
        audioLevel = 0
        return buffer.drain()
    }

    private static func process(pcm: AVAudioPCMBuffer,
                                converter: AVAudioConverter,
                                target: AVAudioFormat,
                                sink: SampleBuffer) {
        let ratio = target.sampleRate / pcm.format.sampleRate
        let outFrames = AVAudioFrameCount(Double(pcm.frameLength) * ratio + 16)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outFrames) else { return }

        var fed = false
        var error: NSError?
        let status = converter.convert(to: outBuf, error: &error) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return pcm
        }
        guard status != .error, outBuf.frameLength > 0,
              let ptr = outBuf.floatChannelData?[0] else { return }
        sink.append(ptr: ptr, count: Int(outBuf.frameLength))
    }
}

/// Lock-protected sample sink shared between the realtime audio thread and the main actor.
final class SampleBuffer: @unchecked Sendable {
    private var samples: [Float] = []
    private var rollingPeak: Float = 0
    private let lock = NSLock()

    func append(ptr: UnsafePointer<Float>, count: Int) {
        // Compute peak before taking the lock to keep the realtime path fast.
        var peak: Float = 0
        for i in 0..<count {
            let a = abs(ptr[i])
            if a > peak { peak = a }
        }
        lock.lock(); defer { lock.unlock() }
        samples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: count))
        if peak > rollingPeak { rollingPeak = peak }
    }

    func drain() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let out = samples
        samples.removeAll(keepingCapacity: true)
        return out
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        samples.removeAll(keepingCapacity: true)
        rollingPeak = 0
    }

    /// Reads and resets the running peak — used by the VU-meter timer.
    func takePeak() -> Float {
        lock.lock(); defer { lock.unlock() }
        let p = rollingPeak
        rollingPeak = 0
        return p
    }
}
