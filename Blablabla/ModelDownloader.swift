import Foundation
import CryptoKit
import OSLog
import MLXLMCommon

/// Resumable Hugging Face snapshot downloader.
///
/// Replaces `HubClient` for the LLM weights: the stock client loses a partial
/// file on any network error, so a single 3 GB `model.safetensors` restarts
/// from zero after every Wi-Fi hiccup, VPN reconnect or laptop sleep. Here each
/// file streams into a `.part` next to its final location; a failed attempt
/// resumes with an HTTP `Range` request from however many bytes reached disk.
///
/// Files land in `~/Library/Application Support/Blablabla/Models/<repo id>/`.
/// A snapshot already sitting in the shared HF cache (`~/.cache/huggingface/hub`)
/// is reused as-is so existing installs don't re-download.
nonisolated struct ModelDownloader: Downloader {
    /// Base URL of the hub (huggingface.co or a mirror with the same API).
    let host: URL

    static let defaultHost = URL(string: "https://huggingface.co")!
    static let hostKey = "blabla.llm.downloadHost"

    /// Host from Settings; falls back to huggingface.co on empty/invalid input.
    static var configuredHost: URL {
        let raw = UserDefaults.standard.string(forKey: hostKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let url = URL(string: raw), url.scheme?.hasPrefix("http") == true, url.host != nil else {
            return defaultHost
        }
        return url
    }

    private static let log = Logger(subsystem: "blablabla", category: "download")
    private static let completeMarker = ".blablabla-complete"

    /// Consecutive attempts without a single new byte before we give up.
    private static let maxStalledAttempts = 6

    static func localDirectory(for id: String) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
        return support.appendingPathComponent("Blablabla/Models/\(id)", isDirectory: true)
    }

    /// True when the weights are already on disk (ours or the shared HF cache).
    static func isAvailableLocally(id: String) -> Bool {
        let marker = localDirectory(for: id).appendingPathComponent(completeMarker)
        return FileManager.default.fileExists(atPath: marker.path) || legacyHubSnapshot(for: id) != nil
    }

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        let dir = Self.localDirectory(for: id)
        let marker = dir.appendingPathComponent(Self.completeMarker)
        let fm = FileManager.default

        if !useLatest {
            if fm.fileExists(atPath: marker.path) { return dir }
            if let legacy = Self.legacyHubSnapshot(for: id) {
                Self.log.info("Reusing HF cache snapshot at \(legacy.path, privacy: .public)")
                return legacy
            }
        }

        let revision = revision ?? "main"
        let files = try await listFiles(id: id, revision: revision)
            .filter { file in patterns.contains { Self.glob($0, matches: file.path) } }
        guard !files.isEmpty else {
            throw DownloadError.noMatchingFiles(id)
        }

        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let total = files.reduce(Int64(0)) { $0 + $1.size }
        let progress = Progress(totalUnitCount: max(total, 1))
        var finished: Int64 = 0

        for file in files {
            let dest = dir.appendingPathComponent(file.path)
            if Self.fileSize(at: dest) == file.size {
                finished += file.size
                progress.completedUnitCount = finished
                progressHandler(progress)
                continue
            }
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let base = finished
            try await downloadFile(id: id, revision: revision, file: file, to: dest) { bytes in
                progress.completedUnitCount = base + bytes
                progressHandler(progress)
            }
            finished += file.size
        }

        // Only a pass that fetched weights marks the snapshot complete — a
        // tokenizer-only pass (`*.json`) must not short-circuit the next call.
        if files.contains(where: { $0.path.hasSuffix(".safetensors") }) {
            fm.createFile(atPath: marker.path, contents: nil)
        }
        return dir
    }

    // MARK: - Listing

    private struct RemoteFile: Decodable {
        struct LFS: Decodable { let oid: String; let size: Int64 }
        let type: String
        let path: String
        let size: Int64
        let lfs: LFS?
    }

    private func listFiles(id: String, revision: String) async throws -> [RemoteFile] {
        var comps = URLComponents(url: host.appendingPathComponent("api/models/\(id)/tree/\(revision)"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "recursive", value: "true")]
        var request = URLRequest(url: comps.url!, timeoutInterval: 30)
        request.setValue("Blablabla", forHTTPHeaderField: "User-Agent")

        var lastError: Error = DownloadError.listingFailed(host.absoluteString)
        for attempt in 0..<4 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw DownloadError.badResponse(-1) }
                guard http.statusCode == 200 else { throw DownloadError.badResponse(http.statusCode) }
                return try JSONDecoder().decode([RemoteFile].self, from: data).filter { $0.type == "file" }
            } catch {
                lastError = error
                if case DownloadError.badResponse(let code) = error, (400..<500).contains(code) { break }
                try await Task.sleep(for: .seconds(1 << attempt))
            }
        }
        throw lastError
    }

    // MARK: - Resumable file download

    private func downloadFile(
        id: String,
        revision: String,
        file: RemoteFile,
        to dest: URL,
        onBytes: @Sendable @escaping (Int64) -> Void
    ) async throws {
        let part = dest.appendingPathExtension("part")
        let url = host.appendingPathComponent("\(id)/resolve/\(revision)/\(file.path)")
        var stalled = 0

        while true {
            try Task.checkCancellation()
            let before = Self.fileSize(at: part) ?? 0
            if before > file.size {
                try? FileManager.default.removeItem(at: part)
                continue
            }
            if before == file.size { break }

            do {
                try await StreamingTransfer.run(url: url, appendingTo: part, offset: before, onBytes: onBytes)
                break
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let after = Self.fileSize(at: part) ?? 0
                stalled = after > before ? 0 : stalled + 1
                Self.log.error("""
                    \(file.path, privacy: .public): attempt failed at \(after)/\(file.size) bytes \
                    (stalled \(stalled)): \(error.localizedDescription, privacy: .public)
                    """)
                if case DownloadError.badResponse(let code) = error, (400..<500).contains(code), code != 416 {
                    throw error
                }
                if stalled >= Self.maxStalledAttempts { throw error }
                try await Task.sleep(for: .seconds(min(30, 1 << stalled)))
            }
        }

        guard Self.fileSize(at: part) == file.size else {
            throw DownloadError.sizeMismatch(file.path)
        }
        if let oid = file.lfs?.oid, try Self.sha256(of: part) != oid {
            try? FileManager.default.removeItem(at: part)
            throw DownloadError.checksumMismatch(file.path)
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: part, to: dest)
    }

    // MARK: - Helpers

    /// A complete snapshot left by the stock HubClient (earlier app versions).
    private static func legacyHubSnapshot(for id: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let snapshots = home.appendingPathComponent(
            ".cache/huggingface/hub/models--\(id.replacingOccurrences(of: "/", with: "--"))/snapshots")
        guard let revisions = try? FileManager.default.contentsOfDirectory(
            at: snapshots, includingPropertiesForKeys: nil) else { return nil }

        for dir in revisions {
            let config = dir.appendingPathComponent("config.json")
            guard FileManager.default.fileExists(atPath: config.path) else { continue }
            var shards: Set<String> = ["model.safetensors"]
            let index = dir.appendingPathComponent("model.safetensors.index.json")
            if let data = try? Data(contentsOf: index),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let map = json["weight_map"] as? [String: String] {
                shards = Set(map.values)
            }
            // Symlinks into blobs/ — fileExists follows them, so a missing blob fails here.
            if shards.allSatisfy({ FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }) {
                return dir
            }
        }
        return nil
    }

    private static func fileSize(at url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func glob(_ pattern: String, matches path: String) -> Bool {
        fnmatch(pattern, path, 0) == 0
    }

    enum DownloadError: LocalizedError {
        case listingFailed(String)
        case badResponse(Int)
        case noMatchingFiles(String)
        case sizeMismatch(String)
        case checksumMismatch(String)

        var errorDescription: String? {
            switch self {
            case .listingFailed(let host): return "Couldn't reach \(host)"
            case .badResponse(let code): return "Server returned HTTP \(code)"
            case .noMatchingFiles(let id): return "No model files found in \(id)"
            case .sizeMismatch(let path): return "\(path) has an unexpected size"
            case .checksumMismatch(let path): return "\(path) failed checksum — re-downloading on retry"
            }
        }
    }
}

/// One HTTP request that streams its body straight onto the end of a file.
/// Bytes hit disk as they arrive, so whatever made it before a failure is kept.
nonisolated private final class StreamingTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let handle: FileHandle
    private var written: Int64
    private let onBytes: @Sendable (Int64) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private var lastReport: Int64 = 0

    private init(handle: FileHandle, offset: Int64, onBytes: @Sendable @escaping (Int64) -> Void) {
        self.handle = handle
        self.written = offset
        self.onBytes = onBytes
    }

    static func run(url: URL, appendingTo part: URL, offset: Int64,
                    onBytes: @Sendable @escaping (Int64) -> Void) async throws {
        if !FileManager.default.fileExists(atPath: part.path) {
            FileManager.default.createFile(atPath: part.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: part)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(offset))
        try handle.seekToEnd()

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60           // idle gap between packets
        config.timeoutIntervalForResource = 6 * 3600
        config.waitsForConnectivity = true

        var request = URLRequest(url: url)
        request.setValue("Blablabla", forHTTPHeaderField: "User-Agent")
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }

        let transfer = StreamingTransfer(handle: handle, offset: offset, onBytes: onBytes)
        let session = URLSession(configuration: config, delegate: transfer, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                transfer.continuation = cont
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        switch status {
        case 206:
            completionHandler(.allow)
        case 200:
            // Server ignored Range — start the file over.
            do {
                try handle.truncate(atOffset: 0)
                written = 0
                completionHandler(.allow)
            } catch {
                failure = error
                completionHandler(.cancel)
            }
        default:
            failure = ModelDownloader.DownloadError.badResponse(status)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle.write(contentsOf: data)
            written += Int64(data.count)
            if written - lastReport >= 1 << 20 {
                lastReport = written
                onBytes(written)
            }
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        onBytes(written)
        if let failure {
            continuation?.resume(throwing: failure)
        } else if let error {
            let cancelled = (error as NSError).code == NSURLErrorCancelled
            continuation?.resume(throwing: cancelled ? CancellationError() : error)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}
