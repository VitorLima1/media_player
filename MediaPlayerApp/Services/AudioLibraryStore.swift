import AVFoundation
import Foundation

protocol AudioLibraryStoring: Sendable {
    func loadTracks() async throws -> [AudioTrack]
    func importItems(from urls: [URL]) async throws -> [AudioTrack]
    func delete(_ tracks: [AudioTrack]) async throws
}

struct AudioLibraryStore: AudioLibraryStoring {
    static let supportedFileExtensions: Set<String> = ["mp3", "wav", "flac", "m4a"]

    static var libraryDirectory: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Music", isDirectory: true)
    }

    private var fileManager: FileManager {
        .default
    }

    func loadTracks() async throws -> [AudioTrack] {
        try ensureDirectoriesExist()

        var tracks = try loadIndex()
            .filter { fileManager.fileExists(atPath: $0.fileURL.path) }

        let indexedFileNames = Set(tracks.map(\.storedFileName))
        let localFiles = try audioFiles(in: Self.libraryDirectory)
            .filter { !indexedFileNames.contains($0.lastPathComponent) }

        for fileURL in localFiles {
            let track = try await makeTrack(
                forLocalFile: fileURL,
                sourceFileName: fileURL.lastPathComponent,
                storedFileName: fileURL.lastPathComponent
            )
            tracks.append(track)
        }

        tracks.sort { $0.importedAt < $1.importedAt }
        try saveIndex(tracks)
        return tracks
    }

    func importItems(from urls: [URL]) async throws -> [AudioTrack] {
        try ensureDirectoriesExist()

        var tracks = try await loadTracks()
        var importedTracks: [AudioTrack] = []

        for url in urls {
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let candidates = try audioFiles(in: url)
            for sourceURL in candidates {
                let track = try await importFile(from: sourceURL)
                tracks.append(track)
                importedTracks.append(track)
            }
        }

        tracks.sort { $0.importedAt < $1.importedAt }
        try saveIndex(tracks)
        return importedTracks
    }

    func delete(_ tracks: [AudioTrack]) async throws {
        try ensureDirectoriesExist()

        let idsToDelete = Set(tracks.map(\.id))
        var currentTracks = try await loadTracks()

        for track in tracks {
            if fileManager.fileExists(atPath: track.fileURL.path) {
                try fileManager.removeItem(at: track.fileURL)
            }
        }

        currentTracks.removeAll { idsToDelete.contains($0.id) }
        try saveIndex(currentTracks)
    }

    private func importFile(from sourceURL: URL) async throws -> AudioTrack {
        let storedFileName = "\(UUID().uuidString).\(sourceURL.pathExtension.lowercased())"
        let destinationURL = Self.libraryDirectory.appendingPathComponent(storedFileName)

        try coordinatedCopy(from: sourceURL, to: destinationURL)

        return try await makeTrack(
            forLocalFile: destinationURL,
            sourceFileName: sourceURL.lastPathComponent,
            storedFileName: storedFileName
        )
    }

    private func makeTrack(
        forLocalFile url: URL,
        sourceFileName: String,
        storedFileName: String
    ) async throws -> AudioTrack {
        let asset = AVURLAsset(url: url)
        let metadata = (try? await asset.load(.commonMetadata)) ?? []
        let assetDuration = try? await asset.load(.duration)
        let duration = assetDuration?.seconds ?? 0

        let title = await metadataString(.commonKeyTitle, in: metadata)
            ?? URL(fileURLWithPath: sourceFileName).deletingPathExtension().lastPathComponent

        return AudioTrack(
            id: UUID(),
            sourceFileName: sourceFileName,
            storedFileName: storedFileName,
            title: title,
            artist: await metadataString(.commonKeyArtist, in: metadata),
            album: await metadataString(.commonKeyAlbumName, in: metadata),
            duration: duration.isFinite ? duration : 0,
            importedAt: Date()
        )
    }

    private func metadataString(
        _ key: AVMetadataKey,
        in metadata: [AVMetadataItem]
    ) async -> String? {
        guard let item = AVMetadataItem.metadataItems(
            from: metadata,
            withKey: key,
            keySpace: .common
        ).first else {
            return nil
        }

        return try? await item.load(.stringValue)
    }

    private func audioFiles(in url: URL) throws -> [URL] {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true {
            let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )

            return (enumerator?.compactMap { item -> URL? in
                guard let fileURL = item as? URL else {
                    return nil
                }

                return Self.isSupportedAudioFile(fileURL) ? fileURL : nil
            } ?? [])
        }

        return Self.isSupportedAudioFile(url) ? [url] : []
    }

    private static func isSupportedAudioFile(_ url: URL) -> Bool {
        supportedFileExtensions.contains(url.pathExtension.lowercased())
    }

    private func coordinatedCopy(from sourceURL: URL, to destinationURL: URL) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var copyError: Error?

        coordinator.coordinate(
            readingItemAt: sourceURL,
            options: [],
            error: &coordinationError
        ) { readableURL in
            do {
                try fileManager.copyItem(at: readableURL, to: destinationURL)
            } catch {
                copyError = error
            }
        }

        if let copyError {
            throw copyError
        }

        if let coordinationError {
            throw coordinationError
        }
    }

    private func ensureDirectoriesExist() throws {
        try fileManager.createDirectory(
            at: Self.libraryDirectory,
            withIntermediateDirectories: true
        )

        try fileManager.createDirectory(
            at: indexURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    private var indexURL: URL {
        fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AudioLibrary", isDirectory: true)
            .appendingPathComponent("tracks.json")
    }

    private func loadIndex() throws -> [AudioTrack] {
        guard fileManager.fileExists(atPath: indexURL.path) else {
            return []
        }

        let data = try Data(contentsOf: indexURL)
        return try JSONDecoder().decode([AudioTrack].self, from: data)
    }

    private func saveIndex(_ tracks: [AudioTrack]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(tracks)
        try data.write(to: indexURL, options: [.atomic])
    }
}
