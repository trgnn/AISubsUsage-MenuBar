// Ordering rules for Accounts ▸ Move Up/Down, kept free of AppKit so they
// can be unit-tested. Keys are "claude:…", "openai", "figma:…".
enum AccountOrder {
    /// Saved keys first, in saved order; unknown (new) keys keep their
    /// default order after them.
    static func sorted<T>(_ items: [T], key: (T) -> String, saved: [String]) -> [T] {
        let rank = Dictionary(saved.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        return items.enumerated().sorted { a, b in
            let ra = rank[key(a.element)] ?? Int.max, rb = rank[key(b.element)] ?? Int.max
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    /// New saved order after moving `key` by `offset` within `current` (the
    /// visible list); nil when it can't move. Saved keys of accounts absent
    /// right now (failed fetch, logged out) keep their place at the end.
    static func moving(_ key: String, by offset: Int, in current: [String], saved: [String]) -> [String]? {
        var keys = current
        guard let i = keys.firstIndex(of: key), keys.indices.contains(i + offset) else { return nil }
        keys.swapAt(i, i + offset)
        return keys + saved.filter { !keys.contains($0) }
    }
}
