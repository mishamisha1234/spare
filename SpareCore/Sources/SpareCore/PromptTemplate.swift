import Foundation

/// Renders `{{placeholder}}` tokens in the prompt constants.
///
/// Prompt *text* lives entirely in `Prompts.swift` as plain string constants,
/// with no Swift interpolation inside it — so the wording can be rewritten
/// wholesale without touching code. This is the only piece that knows how to
/// substitute values into it.
public enum PromptTemplate {

    public static func render(_ template: String, _ values: [String: String]) -> String {
        var output = template
        for (key, value) in values {
            output = output.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return output
    }

    /// Every `{{token}}` still present after rendering. Should always be empty
    /// for a correctly-supplied template — asserted in tests, so a renamed
    /// placeholder can't silently ship as literal `{{work}}` text in a prompt.
    public static func unresolvedPlaceholders(in text: String) -> [String] {
        var found: [String] = []
        var remainder = Substring(text)

        while let open = remainder.range(of: "{{") {
            let afterOpen = remainder[open.upperBound...]
            guard let close = afterOpen.range(of: "}}") else { break }
            found.append(String(afterOpen[..<close.lowerBound]))
            remainder = afterOpen[close.upperBound...]
        }
        return found
    }

    /// Placeholders declared by a template, for test coverage of the values
    /// each call site must supply.
    public static func placeholders(in template: String) -> Set<String> {
        Set(unresolvedPlaceholders(in: template))
    }
}
