import Foundation

/// Subsequence fuzzy matching for the ⌘P file finder.
///
/// Every query character must appear in order in the candidate
/// (case-insensitive). Higher scores mean better matches: boundary hits
/// (start, after "/", ".", "-", "_") and consecutive runs score extra, and
/// shorter candidates win ties.
public enum FuzzyMatcher {
    public static func score(candidate: String, query: String) -> Int? {
        if query.isEmpty { return 0 }
        let cand = Array(candidate.lowercased())
        let quer = Array(query.lowercased())
        guard quer.count <= cand.count else { return nil }

        var score = 0
        var candIndex = 0
        var previousMatchIndex = -2

        for qChar in quer {
            var found = false
            while candIndex < cand.count {
                if cand[candIndex] == qChar {
                    var gain = 1
                    if candIndex == 0 {
                        gain += 4
                    } else {
                        let prev = cand[candIndex - 1]
                        if prev == "/" { gain += 4 }
                        else if prev == "." || prev == "-" || prev == "_" { gain += 2 }
                    }
                    if candIndex == previousMatchIndex + 1 { gain += 3 }
                    score += gain
                    previousMatchIndex = candIndex
                    candIndex += 1
                    found = true
                    break
                }
                candIndex += 1
            }
            if !found { return nil }
        }
        // Prefer shorter candidates and matches that end early.
        score -= cand.count / 8
        return score
    }

    /// Ranks candidates against a query, best first, capped at `limit`.
    public static func rank(candidates: [String], query: String, limit: Int = 50) -> [String] {
        if query.isEmpty { return Array(candidates.prefix(limit)) }
        return candidates
            .compactMap { path -> (String, Int)? in
                guard let s = score(candidate: path, query: query) else { return nil }
                return (path, s)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }
}
