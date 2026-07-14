import Foundation

/// In-memory mapping from opaque repobrowser:// host identifiers to open
/// repository sessions. The scheme handler consults this to serve requests.
public final class RepoSessionRegistry: @unchecked Sendable {
    private var sessions: [String: RepoSession] = [:]
    private let lock = NSLock()

    public init() {}

    public func register(_ session: RepoSession) {
        lock.lock(); defer { lock.unlock() }
        sessions[session.id] = session
    }

    public func session(forHost host: String) -> RepoSession? {
        lock.lock(); defer { lock.unlock() }
        return sessions[host.lowercased()]
    }

    /// Removes the session and discards its in-memory data.
    public func close(id: String) {
        lock.lock()
        let session = sessions.removeValue(forKey: id)
        lock.unlock()
        if let session {
            Task { await session.close() }
        }
    }

    public var allSessions: [RepoSession] {
        lock.lock(); defer { lock.unlock() }
        return Array(sessions.values)
    }
}
