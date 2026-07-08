import Combine
import Foundation

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published private(set) var tracks: [AudioTrack] = []
    @Published private(set) var isImporting = false
    @Published var errorMessage: String?

    let player: AudioPlayerManager

    private let library: any AudioLibraryStoring
    private var cancellables: Set<AnyCancellable> = []
    private var hasLoadedLibrary = false

    init(
        player: AudioPlayerManager? = nil,
        library: any AudioLibraryStoring = AudioLibraryStore()
    ) {
        self.player = player ?? AudioPlayerManager.shared
        self.library = library

        self.player.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.objectWillChange.send()
                }
            }
            .store(in: &cancellables)

        self.player.$playbackError
            .compactMap { $0 }
            .sink { [weak self] message in
                Task { @MainActor [weak self] in
                    self?.errorMessage = message
                }
            }
            .store(in: &cancellables)
    }

    var currentTrack: AudioTrack? {
        player.currentTrack
    }

    var isPlaying: Bool {
        player.isPlaying
    }

    var currentTime: TimeInterval {
        player.currentTime
    }

    var duration: TimeInterval {
        player.duration
    }

    var volume: Float {
        player.volume
    }

    func loadLibraryIfNeeded() async {
        guard !hasLoadedLibrary else {
            return
        }

        hasLoadedLibrary = true
        await reloadLibrary()
    }

    func reloadLibrary() async {
        do {
            let library = self.library
            let loadedTracks = try await Task.detached(priority: .userInitiated) {
                try await library.loadTracks()
            }.value

            tracks = loadedTracks
            player.updateQueue(loadedTracks)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importItems(from urls: [URL]) {
        guard !urls.isEmpty else {
            return
        }

        isImporting = true

        Task { [weak self] in
            guard let self else {
                return
            }

            do {
                let library = self.library
                _ = try await Task.detached(priority: .userInitiated) {
                    try await library.importItems(from: urls)
                }.value

                await reloadLibrary()
            } catch {
                errorMessage = error.localizedDescription
            }

            isImporting = false
        }
    }

    func deleteTracks(at offsets: IndexSet) {
        let tracksToDelete = offsets.map { tracks[$0] }

        Task { [weak self] in
            guard let self else {
                return
            }

            do {
                let library = self.library
                try await Task.detached(priority: .userInitiated) {
                    try await library.delete(tracksToDelete)
                }.value

                let deletedIDs = Set(tracksToDelete.map(\.id))
                tracks.removeAll { deletedIDs.contains($0.id) }
                player.updateQueue(tracks)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func play(_ track: AudioTrack) {
        guard let index = tracks.firstIndex(of: track) else {
            return
        }

        player.load(queue: tracks, startIndex: index, autoplay: true)
    }

    func togglePlayPause() {
        player.togglePlayPause()
    }

    func next() {
        player.next()
    }

    func previous() {
        player.previous()
    }

    func seek(to time: TimeInterval) {
        player.seek(to: time)
    }

    func setVolume(_ volume: Float) {
        player.volume = min(max(volume, 0), 1)
    }
}
