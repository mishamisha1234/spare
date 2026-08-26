import Foundation
import SwiftData
import SpareCore

/// One funnel event, on this device.
///
/// The whole of the app's instrumentation, and deliberately the least
/// machinery that answers the question: a kind and a timestamp, in the store
/// the app already has. No analytics SDK, no identifiers beyond the ones
/// already in the store, and nothing that leaves the device except the two
/// events `FunnelEvent.isReportedToServer` names.
///
/// Read only by the DEBUG-only Settings screen. It is not deleted with the
/// library and it is not shown to a reader, because it is a wiring check
/// rather than a statistic about them.
@Model
final class StoredFunnelEvent {
    var kindRaw: String
    var at: Date

    init(kind: FunnelEvent, at: Date = .now) {
        self.kindRaw = kind.rawValue
        self.at = at
    }

    /// Nil for a kind this build does not recognise, which is dropped from
    /// the counts rather than guessed at.
    var kind: FunnelEvent? { FunnelEvent(rawValue: kindRaw) }
}
