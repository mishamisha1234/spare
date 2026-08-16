import Foundation
import CoreTransferable
import UniformTypeIdentifiers
import SpareCore

/// The library export, as something `ShareLink` can hand to another app.
///
/// A file rather than a plain `String`: sharing a string offers "Copy" and
/// "Message" but not "Save to Files" or "Open in Obsidian", which is the
/// entire point of exporting. Written to a temporary file with a real
/// `.md` name so the receiving app sees a Markdown document.
struct MarkdownLibraryDocument: Transferable {
    let text: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { document in
            let url = FileManager.default.temporaryDirectory
                .appending(path: MarkdownExport.filename())
            try document.text.write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
        // Fallback for destinations that want text rather than a file
        // (Messages, a note field). Without it those targets show nothing.
        DataRepresentation(exportedContentType: .utf8PlainText) { document in
            Data(document.text.utf8)
        }
    }
}

extension StoredLesson {
    /// Value copy for export. Same discipline as everywhere else: `@Model`
    /// objects don't cross into SpareCore.
    var exportable: ExportableLesson {
        ExportableLesson(
            title: title,
            subtitle: subtitle,
            domainTag: topicTag,
            window: window,
            bodyMarkdown: bodyMarkdown,
            generatedAt: generatedAt,
            completedAt: completedAt
        )
    }
}
