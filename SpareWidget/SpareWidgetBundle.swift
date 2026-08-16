import SwiftUI
import WidgetKit
import SpareCore

struct SpareTimelineEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let lockedWindows: Set<TimeWindow>
}

/// One provider for both widgets — they read the same store and want the
/// same refresh cadence.
struct SpareTimelineProvider: TimelineProvider {

    func placeholder(in context: Context) -> SpareTimelineEntry {
        SpareTimelineEntry(date: .now, snapshot: .placeholder, lockedWindows: [.fifteen, .thirty])
    }

    func getSnapshot(in context: Context, completion: @escaping (SpareTimelineEntry) -> Void) {
        // The gallery preview gets fixture data; a real render reads the
        // store, so what someone previews matches what they'll get.
        let snapshot = context.isPreview ? .placeholder : WidgetSnapshotReader.read()
        completion(SpareTimelineEntry(
            date: .now,
            snapshot: snapshot,
            lockedWindows: context.isPreview ? [.fifteen, .thirty] : WidgetSnapshotReader.lockedWindows()
        ))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SpareTimelineEntry>) -> Void) {
        let entry = SpareTimelineEntry(
            date: .now,
            snapshot: WidgetSnapshotReader.read(),
            lockedWindows: WidgetSnapshotReader.lockedWindows()
        )
        // Hourly rather than aggressive: nothing here changes without the
        // reader opening the app, and the app reloads timelines directly when
        // it does. This is only the backstop.
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: .now) ?? .now.addingTimeInterval(3600)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct DurationWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "app.spare.widget.duration", provider: SpareTimelineProvider()) { entry in
            DurationWidgetView(snapshot: entry.snapshot, lockedWindows: entry.lockedWindows)
                .containerBackground(WidgetPalette.background(.light), for: .widget)
        }
        .configurationDisplayName("How long do you have?")
        .description("Pick a length, or pick up a course where you left it.")
        .supportedFamilies([.systemSmall, .accessoryRectangular])
    }
}

struct LibraryCountWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "app.spare.widget.library", provider: SpareTimelineProvider()) { entry in
            LibraryCountWidgetView(snapshot: entry.snapshot)
                .containerBackground(WidgetPalette.background(.light), for: .widget)
        }
        .configurationDisplayName("Things I now know")
        .description("How many lessons you've finished.")
        .supportedFamilies([.systemMedium])
    }
}

@main
struct SpareWidgetBundle: WidgetBundle {
    var body: some Widget {
        DurationWidget()
        LibraryCountWidget()
    }
}
