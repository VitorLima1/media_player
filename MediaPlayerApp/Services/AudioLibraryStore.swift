import AVFoundation
import Dispatch
import Foundation

protocol AudioLibraryStoring: Sendable {
    func loadTracks() async throws -> [AudioTrack]
    func importItems(from urls: [URL]) async throws -> [AudioTrack]
    func delete(_ tracks: [AudioTrack]) async throws
}

struct AudioLibraryStore: AudioLibraryStoring {
    static let supportedFileExtensions: Set<String> = [
        "mp3", "wav", "flac", "m4a", "caf", "ogg", "oga", "opus", "audio"
    ]
    private static let ubiquitousDownloadTimeoutNanoseconds: UInt64 = 8_000_000_000
    private static let ubiquitousDownloadPollIntervalNanoseconds: UInt64 = 500_000_000

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
            do {
                try await withSecurityScopedAccess(to: url) {
                    try await prepareExternalItemForImport(at: url)

                    let candidates = try audioFiles(in: url)
                    guard !candidates.isEmpty else {
                        throw AudioLibraryImportError.noSupportedAudioFiles(url)
                    }

                    for sourceURL in candidates {
                        do {
                            let track = try await importFile(from: sourceURL)
                            tracks.append(track)
                            importedTracks.append(track)
                        } catch {
                            logImportFailure(for: sourceURL, error: error)
                            throw error
                        }
                    }
                }
            } catch {
                logImportFailure(for: url, error: error)
                throw error
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
        try await withSecurityScopedAccess(to: sourceURL) {
            try await prepareExternalItemForImport(at: sourceURL)

            let storedExtension = try preferredSandboxExtension(for: sourceURL)
            let sanitizedName = sanitizedFileStem(from: sourceURL)
            let storedFileName = "\(UUID().uuidString)-\(sanitizedName).\(storedExtension)"
            let destinationURL = Self.libraryDirectory.appendingPathComponent(storedFileName)

            do {
                try copyIntoSandbox(from: sourceURL, to: destinationURL)
            } catch {
                throw AudioLibraryImportError.copyFailed(sourceURL, underlying: error)
            }

            try validateSandboxCopy(at: destinationURL)

            return try await makeTrack(
                forLocalFile: destinationURL,
                sourceFileName: sourceURL.lastPathComponent,
                storedFileName: storedFileName
            )
        }
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

                return isSupportedAudioFile(fileURL) ? fileURL : nil
            } ?? [])
        }

        return isSupportedAudioFile(url) ? [url] : []
    }

    private func isSupportedAudioFile(_ url: URL) -> Bool {
        if Self.supportedFileExtensions.contains(url.pathExtension.lowercased()) {
            return true
        }

        return (try? detectedContainerExtension(for: url)) != nil
    }

    private func preferredSandboxExtension(for sourceURL: URL) throws -> String {
        let detectedExtension = try detectedContainerExtension(for: sourceURL)
        if let detectedExtension {
            return detectedExtension
        }

        let sourceExtension = sourceURL.pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if Self.supportedFileExtensions.contains(sourceExtension) {
            return sourceExtension
        }

        return "audio"
    }

    private func detectedContainerExtension(for sourceURL: URL) throws -> String? {
        let fileHandle = try FileHandle(forReadingFrom: sourceURL)
        defer {
            try? fileHandle.close()
        }

        guard let data = try fileHandle.read(upToCount: 64), !data.isEmpty else {
            return nil
        }

        let bytes = Array(data)

        if data.starts(with: Data("OggS".utf8)) {
            return "ogg"
        }

        if data.starts(with: Data("caff".utf8)) {
            return "caf"
        }

        if data.starts(with: Data("fLaC".utf8)) {
            return "flac"
        }

        if data.starts(with: Data("ID3".utf8)) || looksLikeMPEGAudioFrame(bytes) {
            return "mp3"
        }

        if data.starts(with: Data("RIFF".utf8)), bytes.count >= 12 {
            let waveMarker = Data(bytes[8..<12])
            if waveMarker == Data("WAVE".utf8) {
                return "wav"
            }
        }

        if bytes.count >= 8 {
            let ftypMarker = Data(bytes[4..<8])
            if ftypMarker == Data("ftyp".utf8) {
                return "m4a"
            }
        }

        return nil
    }

    private func looksLikeMPEGAudioFrame(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 2 else {
            return false
        }

        return bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0
    }

    private func sanitizedFileStem(from sourceURL: URL) -> String {
        let rawName = sourceURL
            .deletingPathExtension()
            .lastPathComponent
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)

        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let pieces = rawName
            .components(separatedBy: allowedCharacters.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let sanitized = pieces.joined(separator: "-")
        return String((sanitized.isEmpty ? "audio" : sanitized).prefix(48))
    }

    private func prepareExternalItemForImport(at url: URL) async throws {
        let values = try readableResourceValues(for: url)

        if values.isDirectory != true, values.isUbiquitousItem == true {
            try await requestUbiquitousDownloadIfNeeded(for: url, values: values)
        }

        try validateLocallyReadableContent(at: url)
    }

    private func readableResourceValues(for url: URL) throws -> URLResourceValues {
        do {
            return try url.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isUbiquitousItemKey,
                    .ubiquitousItemDownloadingStatusKey,
                    .fileSizeKey
                ]
            )
        } catch {
            throw AudioLibraryImportError.resourceValuesUnavailable(url, underlying: error)
        }
    }

    private func requestUbiquitousDownloadIfNeeded(
        for url: URL,
        values: URLResourceValues
    ) async throws {
        let status = values.ubiquitousItemDownloadingStatus
        guard status != .current, status != .downloaded else {
            return
        }

        do {
            try fileManager.startDownloadingUbiquitousItem(at: url)
            print("[AudioLibraryStore] iCloud download requested for \(url.lastPathComponent).")
        } catch {
            throw AudioLibraryImportError.iCloudDownloadFailed(url, underlying: error)
        }

        let deadline = DispatchTime.now().uptimeNanoseconds + Self.ubiquitousDownloadTimeoutNanoseconds

        while DispatchTime.now().uptimeNanoseconds < deadline {
            try Task.checkCancellation()

            let refreshedValues = try readableResourceValues(for: url)
            let refreshedStatus = refreshedValues.ubiquitousItemDownloadingStatus
            if refreshedStatus == .current || refreshedStatus == .downloaded {
                return
            }

            try await Task.sleep(nanoseconds: Self.ubiquitousDownloadPollIntervalNanoseconds)
        }

        throw AudioLibraryImportError.iCloudItemNotAvailable(url, status: status)
    }

    private func validateLocallyReadableContent(at url: URL) throws {
        let values = try readableResourceValues(for: url)
        if values.isDirectory == true {
            return
        }

        guard fileManager.fileExists(atPath: url.path) else {
            throw AudioLibraryImportError.localFileUnavailable(url)
        }

        guard fileManager.isReadableFile(atPath: url.path) else {
            throw AudioLibraryImportError.localFileUnreadable(url)
        }

        do {
            let fileHandle = try FileHandle(forReadingFrom: url)
            defer {
                try? fileHandle.close()
            }

            let sample = try fileHandle.read(upToCount: 1)
            guard sample?.isEmpty == false else {
                throw AudioLibraryImportError.emptyFile(url)
            }
        } catch let error as AudioLibraryImportError {
            throw error
        } catch {
            throw AudioLibraryImportError.readProbeFailed(url, underlying: error)
        }
    }

    private func withSecurityScopedAccess<T>(
        to url: URL,
        operation: () async throws -> T
    ) async throws -> T {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        return try await operation()
    }

    private func logImportFailure(for url: URL, error: Error) {
        let nsError = error as NSError
        print(
            """
            [AudioLibraryStore] Import rejected: \(url.lastPathComponent)
            [AudioLibraryStore] Error: \(error.localizedDescription)
            [AudioLibraryStore] NSError domain=\(nsError.domain) code=\(nsError.code)
            """
        )
    }

    private func copyIntoSandbox(from sourceURL: URL, to destinationURL: URL) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    private func validateSandboxCopy(at url: URL) throws {
        guard url.path.hasPrefix(Self.libraryDirectory.path) else {
            throw AudioLibraryImportError.sandboxCopyInvalid(url)
        }

        try validateLocallyReadableContent(at: url)
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

private enum AudioLibraryImportError: LocalizedError {
    case resourceValuesUnavailable(URL, underlying: Error)
    case iCloudDownloadFailed(URL, underlying: Error)
    case iCloudItemNotAvailable(URL, status: URLUbiquitousItemDownloadingStatus?)
    case localFileUnavailable(URL)
    case localFileUnreadable(URL)
    case emptyFile(URL)
    case readProbeFailed(URL, underlying: Error)
    case copyFailed(URL, underlying: Error)
    case sandboxCopyInvalid(URL)
    case noSupportedAudioFiles(URL)

    var errorDescription: String? {
        switch self {
        case .resourceValuesUnavailable(let url, let underlying):
            return "Nao foi possivel ler os metadados de \(url.lastPathComponent): \(underlying.localizedDescription)"
        case .iCloudDownloadFailed(let url, let underlying):
            return "O iOS nao conseguiu baixar \(url.lastPathComponent) do iCloud: \(underlying.localizedDescription)"
        case .iCloudItemNotAvailable(let url, let status):
            return "O arquivo \(url.lastPathComponent) ainda nao esta disponivel localmente no iCloud. Status: \(status?.rawValue ?? "desconhecido")."
        case .localFileUnavailable(let url):
            return "O arquivo \(url.lastPathComponent) nao existe localmente ou esta apenas como placeholder."
        case .localFileUnreadable(let url):
            return "O arquivo \(url.lastPathComponent) nao pode ser lido pelo app."
        case .emptyFile(let url):
            return "O arquivo \(url.lastPathComponent) esta vazio ou indisponivel localmente."
        case .readProbeFailed(let url, let underlying):
            let nsError = underlying as NSError
            return "Falha de leitura em \(url.lastPathComponent) (domain: \(nsError.domain), code: \(nsError.code)): \(underlying.localizedDescription)"
        case .copyFailed(let url, let underlying):
            return "Falha ao copiar \(url.lastPathComponent) para o sandbox: \(underlying.localizedDescription)"
        case .sandboxCopyInvalid(let url):
            return "A copia local de \(url.lastPathComponent) nao ficou dentro do sandbox do app."
        case .noSupportedAudioFiles(let url):
            return "Nenhum arquivo de audio suportado foi encontrado em \(url.lastPathComponent)."
        }
    }
}
