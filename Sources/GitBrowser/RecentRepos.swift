import Foundation

/// Recently opened repository URLs. Stores only the URL strings the user
/// typed — never repository content — so it does not conflict with the
/// no-persistent-cache rule.
enum RecentRepos {
    private static let key = "RecentRepositoryURLs"
    private static let capacity = 15

    static func all() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func add(_ urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = all().filter { $0 != trimmed }
        list.insert(trimmed, at: 0)
        if list.count > capacity {
            list.removeLast(list.count - capacity)
        }
        UserDefaults.standard.set(list, forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
