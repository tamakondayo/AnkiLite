import Foundation

/// Renders Anki card templates (the mustache-like syntax) into HTML.
///
/// Supports:
///   - `{{Field}}` field substitution
///   - `{{FrontSide}}` (answer side only)
///   - `{{cloze:Field}}` cloze deletion (question & answer behaviour)
///   - `{{#Field}}...{{/Field}}` / `{{^Field}}...{{/Field}}` conditionals
///   - `{{text:Field}}` (strip HTML) & `{{hint:Field}}` helpers
///   - `[sound:xxx]` → `<audio>` conversion
struct AnkiTemplateRenderer {

    enum Side {
        case question
        case answer
    }

    let noteType: NoteType

    init(noteType: NoteType) {
        self.noteType = noteType
    }

    /// Renders one side of a card.
    /// - Parameters:
    ///   - note: the note providing field values.
    ///   - ord: the template index (cloze number = ord + 1).
    ///   - side: question or answer.
    ///   - frontSide: rendered question HTML, required for `{{FrontSide}}` on the answer.
    func render(note: Note, ord: Int, side: Side, frontSide: String? = nil) -> String {
        let template = self.template(forOrd: ord)
        let format = side == .question ? template.qfmt : template.afmt
        var fields = note.fieldMap(for: noteType)

        // FrontSide is available on the answer side.
        if side == .answer, let frontSide {
            fields["FrontSide"] = frontSide
        }

        let clozeNumber = ord + 1
        var output = renderTemplate(format,
                                    fields: fields,
                                    side: side,
                                    clozeNumber: clozeNumber)
        output = convertSoundTags(in: output)
        return output
    }

    /// Returns the template for the given ord, falling back to the first.
    private func template(forOrd ord: Int) -> CardTemplate {
        if let exact = noteType.templates.first(where: { $0.ord == ord }) {
            return exact
        }
        if ord < noteType.templates.count {
            return noteType.templates[ord]
        }
        // Cloze note types share a single template across all cloze numbers.
        return noteType.templates.first ?? CardTemplate(name: "", ord: 0, qfmt: "", afmt: "")
    }

    // MARK: - Core template processing

    private func renderTemplate(_ template: String,
                                fields: [String: String],
                                side: Side,
                                clozeNumber: Int) -> String {
        // 1. Handle conditional sections first (they may contain fields).
        var result = processConditionals(template, fields: fields)
        // 2. Replace field references (including cloze:/text:/hint:).
        result = replaceFields(result, fields: fields, side: side, clozeNumber: clozeNumber)
        return result
    }

    /// Handles `{{#Field}}...{{/Field}}` and `{{^Field}}...{{/Field}}`.
    /// Processes the innermost sections first to support nesting.
    private func processConditionals(_ input: String, fields: [String: String]) -> String {
        var text = input
        // Pattern: {{#Field}} or {{^Field}} ... {{/Field}} (non-greedy, dot-matches-newline).
        let pattern = "\\{\\{([#^])([^}]+)\\}\\}((?:(?!\\{\\{[#^/]).)*?)\\{\\{/\\s*\\2\\s*\\}\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return text
        }

        var didReplace = true
        var guardCounter = 0
        while didReplace && guardCounter < 100 {
            didReplace = false
            guardCounter += 1
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: range) else { break }

            guard let typeRange = Range(match.range(at: 1), in: text),
                  let nameRange = Range(match.range(at: 2), in: text),
                  let bodyRange = Range(match.range(at: 3), in: text),
                  let fullRange = Range(match.range, in: text) else { break }

            let conditionalType = String(text[typeRange])
            let fieldName = String(text[nameRange]).trimmingCharacters(in: .whitespaces)
            let body = String(text[bodyRange])
            let value = fields[fieldName] ?? ""
            let isEmpty = isFieldEmpty(value)

            let keep: Bool
            if conditionalType == "#" {
                keep = !isEmpty        // show if not empty
            } else {
                keep = isEmpty         // show if empty (^)
            }

            text.replaceSubrange(fullRange, with: keep ? body : "")
            didReplace = true
        }
        return text
    }

    /// Replaces all `{{...}}` field references.
    private func replaceFields(_ input: String,
                               fields: [String: String],
                               side: Side,
                               clozeNumber: Int) -> String {
        let pattern = "\\{\\{([^{}]+)\\}\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }

        let nsInput = input as NSString
        var result = ""
        var lastEnd = 0
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: nsInput.length))

        for match in matches {
            result += nsInput.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            lastEnd = match.range.location + match.range.length

            let token = nsInput.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            result += resolveToken(token, fields: fields, side: side, clozeNumber: clozeNumber)
        }
        result += nsInput.substring(from: lastEnd)
        return result
    }

    /// Resolves a single template token to its replacement string.
    private func resolveToken(_ token: String,
                              fields: [String: String],
                              side: Side,
                              clozeNumber: Int) -> String {
        if token == "FrontSide" {
            return fields["FrontSide"] ?? ""
        }

        if let colon = token.firstIndex(of: ":") {
            let filter = String(token[..<colon])
            let fieldName = String(token[token.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            switch filter {
            case "cloze":
                let value = fields[fieldName] ?? ""
                return renderCloze(value, side: side, clozeNumber: clozeNumber)
            case "text":
                return stripHTML(fields[fieldName] ?? "")
            case "hint":
                return renderHint(fields[fieldName] ?? "", fieldName: fieldName)
            case "type":
                // Type-in-the-answer not supported; render nothing.
                return ""
            default:
                // Unknown filter → fall back to the raw field value.
                return fields[fieldName] ?? ""
            }
        }

        // Plain field. Unknown fields render as empty (Anki shows the literal,
        // but empty is the safer/cleaner fallback for an importer).
        return fields[token] ?? ""
    }

    // MARK: - Cloze handling

    /// Renders a cloze field for the given side and active cloze number.
    ///
    /// For matching clozes (`{{c<N>::...}}`):
    ///   - question: `[...]` or `[hint]`
    ///   - answer: `<span class="cloze">answer</span>`
    /// Non-matching clozes always reveal their answer text.
    func renderCloze(_ text: String, side: Side, clozeNumber: Int) -> String {
        let pattern = "\\{\\{c(\\d+)::(.*?)\\}\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return text
        }

        let nsText = text as NSString
        var result = ""
        var lastEnd = 0
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        for match in matches {
            result += nsText.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            lastEnd = match.range.location + match.range.length

            let number = Int(nsText.substring(with: match.range(at: 1))) ?? -1
            let inner = nsText.substring(with: match.range(at: 2))

            // Split answer and optional hint on `::`.
            let parts = splitClozeContent(inner)
            let answer = parts.answer
            let hint = parts.hint

            if number == clozeNumber {
                if side == .question {
                    let placeholder = hint.map { "[\($0)]" } ?? "[...]"
                    result += "<span class=\"cloze\">\(placeholder)</span>"
                } else {
                    result += "<span class=\"cloze\">\(answer)</span>"
                }
            } else {
                // Other clozes: show the plain answer on both sides.
                result += answer
            }
        }
        result += nsText.substring(from: lastEnd)
        return result
    }

    private func splitClozeContent(_ inner: String) -> (answer: String, hint: String?) {
        if let range = inner.range(of: "::") {
            let answer = String(inner[..<range.lowerBound])
            let hint = String(inner[range.upperBound...])
            return (answer, hint.isEmpty ? nil : hint)
        }
        return (inner, nil)
    }

    // MARK: - Helpers

    /// `[sound:foo.mp3]` → an HTML5 `<audio>` element.
    func convertSoundTags(in input: String) -> String {
        let pattern = "\\[sound:([^\\]]+)\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        let nsInput = input as NSString
        var result = ""
        var lastEnd = 0
        for match in regex.matches(in: input, range: NSRange(location: 0, length: nsInput.length)) {
            result += nsInput.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            lastEnd = match.range.location + match.range.length
            let filename = nsInput.substring(with: match.range(at: 1))
            let escaped = filename.replacingOccurrences(of: "\"", with: "&quot;")
            result += "<audio controls src=\"\(escaped)\" class=\"anki-audio\"></audio>"
        }
        result += nsInput.substring(from: lastEnd)
        return result
    }

    private func renderHint(_ value: String, fieldName: String) -> String {
        guard !isFieldEmpty(value) else { return "" }
        // A simple expandable hint.
        return """
        <a class="hint" href="#" onclick="this.style.display='none';\
        this.nextElementSibling.style.display='inline';return false;">\(fieldName)</a>\
        <span class="hint" style="display:none">\(value)</span>
        """
    }

    /// Strips HTML tags, used by the `text:` filter.
    func stripHTML(_ input: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<[^>]+>") else { return input }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.stringByReplacingMatches(in: input, range: range, withTemplate: "")
    }

    /// A field is "empty" for conditional purposes if it has no meaningful content.
    private func isFieldEmpty(_ value: String) -> Bool {
        let stripped = stripHTML(value)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty
    }
}
