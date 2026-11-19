import Foundation

/// Forgiving text search used by the sidebar and the in-page filter fields:
/// case-, accent- and width-insensitive, every word of the query must match
/// the start of a word (or, for 3+ characters, anywhere) in one of the fields.
public enum SearchMatcher {
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    public static func tokens(_ query: String) -> [String] {
        fold(query).split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
    }

    /// Relevance score (higher is better), or nil when the fields don't match.
    /// `fields[0]` is the title: matches there rank above keyword matches.
    public static func score(query: String, fields: [String]) -> Int? {
        let words = tokens(query)
        guard !words.isEmpty else { return nil }
        let folded = fields.map(fold)
        var total = 0
        for word in words {
            var best: Int?
            for (index, field) in folded.enumerated() {
                guard let s = wordScore(word, in: field) else { continue }
                let weighted = index == 0 ? s * 3 : s
                best = max(best ?? 0, weighted)
            }
            guard let best else { return nil }
            total += best
        }
        return total
    }

    public static func matches(query: String, fields: [String]) -> Bool {
        score(query: query, fields: fields) != nil
    }

    /// 4 = the whole field, 3 = field starts with it, 2 = a word starts with
    /// it, 1 = contained (only for words of 3+ characters, so "ca" doesn't
    /// match "application").
    static func wordScore(_ word: String, in field: String) -> Int? {
        if field == word { return 4 }
        if field.hasPrefix(word) { return 3 }
        let separators = CharacterSet.alphanumerics.inverted
        var searchStart = field.startIndex
        while let range = field.range(of: word, range: searchStart..<field.endIndex) {
            if range.lowerBound == field.startIndex { return 3 }
            let before = field[field.index(before: range.lowerBound)]
            if before.unicodeScalars.allSatisfy({ separators.contains($0) }) { return 2 }
            searchStart = field.index(after: range.lowerBound)
        }
        if word.count >= 3, field.contains(word) { return 1 }
        return nil
    }

    /// Indices of `items` that match, best first (stable for equal scores).
    public static func ranked<T>(_ items: [T], query: String, fields: (T) -> [String]) -> [T] {
        items.enumerated()
            .compactMap { pair in score(query: query, fields: fields(pair.element)).map { (pair.offset, $0) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            .map { items[$0.0] }
    }
}

extension Array where Element == ScanResult {
    /// Keeps only items whose name or path contains every word of `query`
    /// (folded); categories left empty are dropped. An empty query returns
    /// the results unchanged.
    public func filtered(matching query: String) -> [ScanResult] {
        let words = SearchMatcher.tokens(query)
        guard !words.isEmpty else { return self }
        return compactMap { result in
            var copy = result
            copy.items = result.items.filter { item in
                let haystack = SearchMatcher.fold(item.name + " " + item.url.path(percentEncoded: false))
                return words.allSatisfy { haystack.contains($0) }
            }
            return copy.items.isEmpty ? nil : copy
        }
    }

    /// The results after a clean: items that were removed — or that lived
    /// inside a removed folder — are dropped, as are emptied categories.
    public func removing(_ removed: Set<URL>) -> [ScanResult] {
        guard !removed.isEmpty else { return self }
        let removedPaths = Set(removed.map { Self.normalizedPath($0) })
        return compactMap { result in
            var copy = result
            copy.items = result.items.filter { item in
                // Walk up the item's ancestors: O(depth) per item.
                var path = Self.normalizedPath(item.url)[...]
                while !path.isEmpty {
                    if removedPaths.contains(String(path)) { return false }
                    guard let slash = path.lastIndex(of: "/") else { break }
                    if slash == path.startIndex {
                        return !(path.count > 1 && removedPaths.contains("/"))
                    }
                    path = path[..<slash]
                }
                return true
            }
            return copy.items.isEmpty ? nil : copy
        }
    }

    private static func normalizedPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
