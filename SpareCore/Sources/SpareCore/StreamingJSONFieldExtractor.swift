import Foundation

/// Pulls one top-level string field out of a JSON object *as it streams*.
///
/// Structured outputs and progressive display pull in opposite directions: the
/// model returns one JSON object, but the reader needs `bodyMarkdown` rendered
/// while the rest of that object is still arriving. This decodes the target
/// field's characters the moment they land, before the object is complete.
///
/// It is a real (if minimal) JSON scanner, not a substring search: it tracks
/// nesting depth and key/value position, so a field name appearing *inside*
/// another value — `{"title": "About bodyMarkdown", "bodyMarkdown": "…"}` —
/// cannot false-positive. It also unescapes as it goes, including `\uXXXX`
/// and surrogate pairs, so what it emits is display-ready text.
public struct StreamingJSONFieldExtractor: Sendable {

    public let field: String

    private enum StringRole {
        case none
        case key
        case targetValue
        case otherValue
    }

    private var depth = 0
    private var inString = false
    private var escaping = false
    private var role: StringRole = .none
    private var expectingValue = false
    private var keyBuffer = ""
    private var lastKey = ""

    private var inUnicodeEscape = false
    private var unicodeDigits = ""
    private var pendingHighSurrogate: UInt32?

    /// Everything decoded for the target field so far.
    public private(set) var accumulated = ""
    /// True once the target field's closing quote has been seen.
    public private(set) var isFieldComplete = false

    public init(field: String) {
        self.field = field
    }

    /// Feeds a chunk; returns only the newly decoded target-field text, so the
    /// caller can append it directly to what the reader is looking at.
    public mutating func consume(_ chunk: String) -> String {
        var emitted = ""
        for character in chunk {
            emitted += process(character)
        }
        return emitted
    }

    // MARK: - Scanner

    private mutating func process(_ character: Character) -> String {
        if inString {
            return processInsideString(character)
        }
        processOutsideString(character)
        return ""
    }

    private mutating func processInsideString(_ character: Character) -> String {
        if inUnicodeEscape {
            unicodeDigits.append(character)
            guard unicodeDigits.count == 4 else { return "" }
            inUnicodeEscape = false
            let digits = unicodeDigits
            unicodeDigits = ""
            guard let value = UInt32(digits, radix: 16) else { return "" }
            return appendScalar(value)
        }

        if escaping {
            escaping = false
            switch character {
            case "n": return append("\n")
            case "t": return append("\t")
            case "r": return append("\r")
            case "b": return append("\u{08}")
            case "f": return append("\u{0C}")
            case "u":
                inUnicodeEscape = true
                unicodeDigits = ""
                return ""
            default:
                // Covers \" \\ \/ and anything else the encoder escaped.
                return append(String(character))
            }
        }

        if character == "\\" {
            escaping = true
            return ""
        }

        if character == "\"" {
            inString = false
            switch role {
            case .key:
                lastKey = keyBuffer
                keyBuffer = ""
            case .targetValue:
                isFieldComplete = true
            case .otherValue, .none:
                break
            }
            role = .none
            return ""
        }

        return append(String(character))
    }

    private mutating func processOutsideString(_ character: Character) {
        switch character {
        case "{":
            depth += 1
            expectingValue = false
        case "[":
            depth += 1
        case "}", "]":
            depth -= 1
            expectingValue = false
        case ":":
            expectingValue = true
        case ",":
            expectingValue = false
        case "\"":
            inString = true
            // Keys only exist directly inside the root object. Anything deeper
            // (nested objects, array elements) is skipped wholesale.
            if depth == 1 && !expectingValue {
                role = .key
                keyBuffer = ""
            } else if depth == 1 && expectingValue {
                role = (lastKey == field && !isFieldComplete) ? .targetValue : .otherValue
            } else {
                role = .otherValue
            }
        default:
            break
        }
    }

    // MARK: - Emission

    private mutating func append(_ text: String) -> String {
        switch role {
        case .key:
            keyBuffer += text
            return ""
        case .targetValue:
            accumulated += text
            return text
        case .otherValue, .none:
            return ""
        }
    }

    private mutating func appendScalar(_ value: UInt32) -> String {
        if let high = pendingHighSurrogate {
            pendingHighSurrogate = nil
            if (0xDC00...0xDFFF).contains(value) {
                let combined = 0x10000 + ((high - 0xD800) << 10) + (value - 0xDC00)
                guard let scalar = Unicode.Scalar(combined) else { return "" }
                return append(String(Character(scalar)))
            }
            // Unpaired high surrogate: drop it and handle this scalar normally.
        }

        if (0xD800...0xDBFF).contains(value) {
            pendingHighSurrogate = value
            return ""
        }

        guard let scalar = Unicode.Scalar(value) else { return "" }
        return append(String(Character(scalar)))
    }
}
