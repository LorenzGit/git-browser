import Foundation

/// A small, bounded, in-memory LRU cache for file bytes.
///
/// Lives only for one repository session; never touches disk. Entries larger
/// than `maxEntryBytes` are not cached at all so a single big file cannot
/// wipe the working set.
public final class LRUByteCache {
    public let maxTotalBytes: Int
    public let maxEntryBytes: Int

    private final class Node {
        let key: String
        let data: Data
        var prev: Node?
        var next: Node?
        init(key: String, data: Data) {
            self.key = key
            self.data = data
        }
    }

    private var map: [String: Node] = [:]
    private var head: Node? // most recently used
    private var tail: Node? // least recently used
    private(set) var totalBytes = 0
    private let lock = NSLock()

    public init(maxTotalBytes: Int = 64 * 1024 * 1024, maxEntryBytes: Int = 8 * 1024 * 1024) {
        self.maxTotalBytes = maxTotalBytes
        self.maxEntryBytes = maxEntryBytes
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return map.count
    }

    public var currentBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return totalBytes
    }

    public func value(forKey key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let node = map[key] else { return nil }
        moveToFront(node)
        return node.data
    }

    public func setValue(_ data: Data, forKey key: String) {
        guard data.count <= maxEntryBytes else { return }
        lock.lock(); defer { lock.unlock() }
        if let existing = map[key] {
            unlink(existing)
            totalBytes -= existing.data.count
            map[key] = nil
        }
        let node = Node(key: key, data: data)
        map[key] = node
        pushFront(node)
        totalBytes += data.count
        while totalBytes > maxTotalBytes, let lru = tail {
            unlink(lru)
            map[lru.key] = nil
            totalBytes -= lru.data.count
        }
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        map.removeAll()
        head = nil
        tail = nil
        totalBytes = 0
    }

    // MARK: - Linked list (callers hold the lock)

    private func pushFront(_ node: Node) {
        node.next = head
        node.prev = nil
        head?.prev = node
        head = node
        if tail == nil { tail = node }
    }

    private func unlink(_ node: Node) {
        node.prev?.next = node.next
        node.next?.prev = node.prev
        if head === node { head = node.next }
        if tail === node { tail = node.prev }
        node.prev = nil
        node.next = nil
    }

    private func moveToFront(_ node: Node) {
        guard head !== node else { return }
        unlink(node)
        pushFront(node)
    }
}
