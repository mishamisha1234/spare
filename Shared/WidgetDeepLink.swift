import Foundation
import SpareCore

/// The URL contract between a widget tap and the app.
///
/// Compiled into both targets so the widget can only ever build a link the
/// app can parse — the round-trip is covered by a test rather than trusted.
///
/// `Link`/`widgetURL` rather than an `AppIntent` for the tap itself: opening
/// the app at a destination is exactly what a URL does, and it survives the
/// widget process being terminated between render and tap. App Intents are
/// used for the Shortcuts-facing actions instead, where running *without*
/// opening the app is the point.
enum WidgetDeepLink: Equatable {
    /// Skip Home, go straight to suggestions for this length.
    case suggestions(TimeWindow)
    /// A locked length. Opens the paywall rather than suggestions, so a free
    /// user tapping "30 min" on the widget gets the honest answer instead of
    /// a screen they can't act on.
    case paywall(TimeWindow)
    /// Resume a part-read course at a chapter.
    case resumeCourse(lessonID: UUID, chapterIndex: Int)

    static let scheme = "spare"

    var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .suggestions(let window):
            components.host = "suggestions"
            components.queryItems = [URLQueryItem(name: "window", value: window.rawValue)]
        case .paywall(let window):
            components.host = "paywall"
            components.queryItems = [URLQueryItem(name: "window", value: window.rawValue)]
        case .resumeCourse(let lessonID, let chapterIndex):
            components.host = "resume"
            components.queryItems = [
                URLQueryItem(name: "lesson", value: lessonID.uuidString),
                URLQueryItem(name: "chapter", value: String(chapterIndex)),
            ]
        }
        return components.url
    }

    init?(url: URL) {
        guard
            url.scheme == Self.scheme,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }

        let query = Dictionary(
            (components.queryItems ?? []).compactMap { item -> (String, String)? in
                guard let value = item.value else { return nil }
                return (item.name, value)
            },
            uniquingKeysWith: { first, _ in first }
        )

        switch components.host {
        case "suggestions":
            guard let raw = query["window"], let window = TimeWindow.stored(rawValue: raw) else { return nil }
            self = .suggestions(window)
        case "paywall":
            guard let raw = query["window"], let window = TimeWindow.stored(rawValue: raw) else { return nil }
            self = .paywall(window)
        case "resume":
            guard
                let raw = query["lesson"],
                let lessonID = UUID(uuidString: raw),
                let chapter = query["chapter"].flatMap(Int.init)
            else { return nil }
            self = .resumeCourse(lessonID: lessonID, chapterIndex: chapter)
        default:
            return nil
        }
    }
}
