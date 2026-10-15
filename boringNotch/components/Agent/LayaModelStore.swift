//
//  LayaModelStore.swift
//  boringNotch
//
//  Downloads the on-device decision model once, into the app's own Application Support, and
//  verifies every file against the release manifest. The app itself stays small; the model is
//  only fetched when the user chooses Local or Shadow decisions.
//

import CryptoKit
import Defaults
import Foundation
import OSLog

private let log = Logger(subsystem: "io.otron.notch", category: "laya")

extension Defaults.Keys {
    static let layaManifestURL = Key<String>(
        "layaManifestURL",
        default: "https://github.com/MoMia7/boring.notch/releases/download/laya-notch-1/manifest.json"
    )
}

/// manifest.json published with each model release.
struct LayaManifest: Codable {
    struct File: Codable {
        let url: String
        /// Path inside the model folder, e.g. "Laya.mlpackage/Data/com.apple.CoreML/weights/weight.bin".
        let path: String
        let size: Int64
        let sha256: String
    }

    let version: String
    let files: [File]

    var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }
}

@MainActor
final class LayaModelStore: ObservableObject {
    static let shared = LayaModelStore()

    enum Status: Equatable {
        case notInstalled
        case downloading(Double)
        case installed(String)
        case failed(String)
    }

    @Published private(set) var status: Status = .notInstalled
    private var download: Task<Void, Never>?

    private let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("NotchAgent/Laya", isDirectory: true)
    }()

    private init() {
        if let version = installedVersion { status = .installed(version) }
    }

    /// The folder holding laya.json, tokenizer.json and Laya.mlpackage, when installed.
    var modelDirectory: URL? {
        guard let version = installedVersion else { return nil }
        return root.appendingPathComponent(version, isDirectory: true)
    }

    private var installedVersion: String? {
        let marker = root.appendingPathComponent("current")
        guard let version = try? String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !version.isEmpty,
              FileManager.default.fileExists(atPath: root.appendingPathComponent(version).appendingPathComponent("laya.json").path)
        else { return nil }
        return version
    }

    func install() {
        guard download == nil else { return }
        status = .downloading(0)
        download = Task {
            do {
                let version = try await fetch()
                status = .installed(version)
                log.notice("laya model \(version, privacy: .public) installed")
            } catch is CancellationError {
                status = installedVersion.map { .installed($0) } ?? .notInstalled
            } catch {
                status = .failed(error.localizedDescription)
                log.error("laya download failed: \(error.localizedDescription, privacy: .public)")
            }
            download = nil
        }
    }

    func cancel() {
        download?.cancel()
    }

    func remove() {
        download?.cancel()
        Task { await LayaEngine.shared.unload() }
        try? FileManager.default.removeItem(at: root)
        status = .notInstalled
    }

    private func fetch() async throws -> String {
        guard let manifestURL = URL(string: Defaults[.layaManifestURL]) else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(from: manifestURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let manifest = try JSONDecoder().decode(LayaManifest.self, from: data)
        guard manifest.version.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
            throw URLError(.cannotParseResponse)
        }

        let fm = FileManager.default
        let staging = root.appendingPathComponent(".download-\(manifest.version)", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let total = Double(max(1, manifest.totalSize))
        var done: Int64 = 0
        for file in manifest.files {
            try Task.checkCancellation()
            // paths come from the manifest; refuse anything that could leave the model folder
            guard !file.path.hasPrefix("/"), !file.path.split(separator: "/").contains(".."),
                  let url = URL(string: file.url) else { throw URLError(.cannotParseResponse) }
            let base = done
            let temp = try await LayaDownloader.download(url) { written in
                Task { @MainActor in self.status = .downloading(Double(base + written) / total) }
            }
            guard try Self.sha256(of: temp) == file.sha256.lowercased() else {
                try? fm.removeItem(at: temp)
                throw NSError(domain: "Laya", code: 1, userInfo: [NSLocalizedDescriptionKey: "Checksum mismatch for \(file.path)"])
            }
            let dest = staging.appendingPathComponent(file.path)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: temp, to: dest)
            done += file.size
            status = .downloading(Double(done) / total)
        }

        let final = root.appendingPathComponent(manifest.version, isDirectory: true)
        try? fm.removeItem(at: final)
        try fm.moveItem(at: staging, to: final)
        try manifest.version.write(to: root.appendingPathComponent("current"), atomically: true, encoding: .utf8)
        // older versions are no longer needed
        for item in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        where item.hasDirectoryPath && item.lastPathComponent != manifest.version {
            try? fm.removeItem(at: item)
        }
        return manifest.version
    }

    private nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// A file download with byte progress, delivered to a temporary file we own.
private final class LayaDownloader: NSObject, URLSessionDownloadDelegate {
    private let progress: (Int64) -> Void
    private var continuation: CheckedContinuation<URL, Error>?

    private init(progress: @escaping (Int64) -> Void) {
        self.progress = progress
    }

    static func download(_ url: URL, progress: @escaping (Int64) -> Void) async throws -> URL {
        let delegate = LayaDownloader(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // the system deletes `location` when this returns, so move it somewhere we own first
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            guard status == 200 else { throw URLError(.badServerResponse) }
            try FileManager.default.moveItem(at: location, to: kept)
            continuation?.resume(returning: kept)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
