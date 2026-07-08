import Foundation

struct AudioTrack: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let sourceFileName: String
    let storedFileName: String
    let title: String
    let artist: String?
    let album: String?
    let duration: TimeInterval
    let importedAt: Date

    var displayTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }

        return URL(fileURLWithPath: sourceFileName).deletingPathExtension().lastPathComponent
    }

    var displaySubtitle: String {
        [artist, album]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " - ")
    }

    var fileURL: URL {
        AudioLibraryStore.libraryDirectory.appendingPathComponent(storedFileName)
    }
}
