import Foundation

/// Manages the single temporary file the media preview may need when a native
/// media API requires a seekable file.
///
/// Guarantees:
///   - each temp file contains exactly one selected media asset, never any
///     other repository content;
///   - files live in the system temporary directory;
///   - a file is deleted when its preview closes;
///   - leftovers from a crash are swept at app startup;
///   - this is playback plumbing, not a repository cache.
public final class TempMediaFileManager: @unchecked Sendable {
    public static let shared = TempMediaFileManager()

    private let directory: URL
    private var live: Set<URL> = []
    private let lock = NSLock()

    public init(directoryName: String = "GitBrowserMediaPreview") {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Deletes anything left behind by a previous crashed run.
    public func sweepAtStartup() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Writes one media asset to a fresh temp file and returns its URL.
    public func makeTempFile(data: Data, fileExtension: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeExt = fileExtension.isEmpty ? "bin" : fileExtension
        let url = directory.appendingPathComponent("\(UUID().uuidString).\(safeExt)")
        try data.write(to: url, options: [.atomic])
        lock.lock()
        live.insert(url)
        lock.unlock()
        return url
    }

    /// Deletes the temp file backing a closed preview.
    public func remove(_ url: URL) {
        lock.lock()
        live.remove(url)
        lock.unlock()
        try? FileManager.default.removeItem(at: url)
    }

    /// Deletes every live temp file (app shutdown).
    public func removeAll() {
        lock.lock()
        let urls = live
        live.removeAll()
        lock.unlock()
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
        try? FileManager.default.removeItem(at: directory)
    }
}
