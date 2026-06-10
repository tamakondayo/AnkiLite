import Foundation
import GRDB

/// Parses an Anki-style browser search query into SQL WHERE fragments.
///
/// Supported syntax (a useful subset of Anki's):
///   - plain words           — substring match on fields / sort field / tags
///   - "quoted phrase"       — spaces inside one term
///   - `deck:name`           — restrict to decks whose name contains `name`
///   - `tag:foo`             — note has tag `foo` (or a `foo::…` subtag)
///   - `flag:1`…`flag:7`     — colour flag; `flag:0` = no flag
///   - `is:new` `is:learn` `is:review` `is:due` `is:suspended` `is:buried`
///   - `-token`              — negate any of the above
///   - `*`                   — wildcard inside words and tag/deck values
///
/// All terms are ANDed, matching Anki's default.
enum BrowserSearch {

    struct Compiled {
        /// Zero or more " AND (…)" fragments to append to the WHERE clause.
        var sqlFragment: String = ""
        var arguments: [(any DatabaseValueConvertible)?] = []
    }

    /// Context the card-state terms need.
    struct Context {
        /// Decks inside the current browsing scope (the browsed deck + descendants).
        var scopeDecks: [Deck]
        /// Rollover-aware day number for `is:due`.
        var todayDays: Int
        /// Unix seconds cutoff for learning cards in `is:due`.
        var nowCutoff: Int64
    }

    static func compile(query: String, context: Context) -> Compiled {
        var out = Compiled()
        for rawToken in tokenize(query) {
            var token = rawToken
            var negated = false
            if token.hasPrefix("-") && token.count > 1 {
                negated = true
                token.removeFirst()
            }
            guard let clause = compileToken(token, context: context, into: &out) else { continue }
            out.sqlFragment += negated ? " AND NOT (\(clause))" : " AND (\(clause))"
        }
        return out
    }

    /// Returns the SQL for one token, appending its bind values to `out`.
    private static func compileToken(_ token: String,
                                     context: Context,
                                     into out: inout Compiled) -> String? {
        let lower = token.lowercased()

        if lower.hasPrefix("deck:") {
            let value = String(token.dropFirst(5))
            guard !value.isEmpty else { return nil }
            let pattern = likePattern(value)
            let ids = context.scopeDecks
                .filter { likeMatches(pattern: pattern, in: $0.name) }
                .map { String($0.id) }
            // No matching deck → match nothing (Anki behaviour).
            return ids.isEmpty ? "0" : "card.did IN (\(ids.joined(separator: ",")))"
        }

        if lower.hasPrefix("tag:") {
            let value = String(token.dropFirst(4))
            guard !value.isEmpty else { return nil }
            let escaped = likeBody(value)
            // Tags are space-separated; also match hierarchical subtags.
            out.arguments.append("% \(escaped) %")
            out.arguments.append("% \(escaped)::%")
            return "(' ' || note.tags || ' ') LIKE ? ESCAPE '\\' OR (' ' || note.tags || ' ') LIKE ? ESCAPE '\\'"
        }

        if lower.hasPrefix("flag:") {
            guard let n = Int(token.dropFirst(5)), (0...7).contains(n) else { return nil }
            return "(card.flags & 7) = \(n)"
        }

        if lower.hasPrefix("is:") {
            switch String(lower.dropFirst(3)) {
            case "new":
                return "card.queue = \(CardQueue.new.rawValue)"
            case "learn", "learning":
                return "card.queue IN (\(CardQueue.learning.rawValue), \(CardQueue.dayLearning.rawValue))"
            case "review":
                return "card.queue = \(CardQueue.review.rawValue)"
            case "due":
                return """
                    (card.queue = \(CardQueue.review.rawValue) AND card.due <= \(context.todayDays)) \
                    OR (card.queue IN (\(CardQueue.learning.rawValue), \(CardQueue.dayLearning.rawValue)) \
                    AND card.due <= \(context.nowCutoff))
                    """
            case "suspended":
                return "card.queue = \(CardQueue.suspended.rawValue)"
            case "buried":
                return "card.queue = \(CardQueue.buried.rawValue)"
            default:
                return nil
            }
        }

        // Plain text: substring across fields, sort field and tags.
        let pattern = likePattern(token)
        out.arguments.append(contentsOf: [pattern, pattern, pattern])
        return "note.flds LIKE ? ESCAPE '\\' OR note.sfld LIKE ? ESCAPE '\\' OR note.tags LIKE ? ESCAPE '\\'"
    }

    // MARK: - Tokenizer

    /// Splits on spaces, honouring double quotes (which may appear after a
    /// prefix, e.g. `deck:"My Deck"`).
    static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for ch in s {
            if ch == "\"" {
                inQuotes.toggle()
                continue
            }
            if (ch == " " || ch == "\u{3000}") && !inQuotes {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    // MARK: - LIKE helpers

    /// Escapes LIKE metacharacters and converts `*` wildcards, without the
    /// surrounding `%…%`.
    static func likeBody(_ term: String) -> String {
        var out = ""
        for ch in term {
            switch ch {
            case "\\", "%", "_": out += "\\\(ch)"
            case "*": out += "%"
            default: out.append(ch)
            }
        }
        return out
    }

    /// Substring LIKE pattern with escaping and `*` wildcard support.
    static func likePattern(_ term: String) -> String {
        "%\(likeBody(term))%"
    }

    /// In-memory equivalent of `LIKE … ESCAPE '\'` (case-insensitive),
    /// used for deck-name matching against the already-loaded deck list.
    static func likeMatches(pattern: String, in text: String) -> Bool {
        // Convert the LIKE pattern back into a regex.
        var regex = ""
        var escaped = false
        for ch in pattern {
            if escaped {
                regex += NSRegularExpression.escapedPattern(for: String(ch))
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "%" {
                regex += ".*"
            } else if ch == "_" {
                regex += "."
            } else {
                regex += NSRegularExpression.escapedPattern(for: String(ch))
            }
        }
        return text.range(of: "^\(regex)$",
                          options: [.regularExpression, .caseInsensitive]) != nil
    }
}
