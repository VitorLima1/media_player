import AVFoundation
import Combine
import Foundation
import MediaPlayer

@MainActor
final class AudioPlayerManager: NSObject, ObservableObject {
    static let shared = AudioPlayerManager()

    @Published private(set) var queue: [AudioTrack] = []
    @Published private(set) var currentTrack: AudioTrack?
    @Published private(set) var currentIndex: Int?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var volume: Float = 0.9 {
        didSet {
            player?.volume = volume
        }
    }
    @Published var playbackError: String?

    private var player: AVPlayer?
    private var playerItemStatusObservation: NSKeyValueObservation?
    private var playbackEndObserver: NSObjectProtocol?
    private var playbackFailureObserver: NSObjectProtocol?
    private var progressTask: Task<Void, Never>?
    private var wasPlayingBeforeInterruption = false
    private let commandCenter = MPRemoteCommandCenter.shared()

    private override init() {
        super.init()
        configureRemoteCommands()
        observeAudioSessionNotifications()
    }

    deinit {
        progressTask?.cancel()
        playerItemStatusObservation?.invalidate()
        if let playbackEndObserver {
            NotificationCenter.default.removeObserver(playbackEndObserver)
        }
        if let playbackFailureObserver {
            NotificationCenter.default.removeObserver(playbackFailureObserver)
        }
        NotificationCenter.default.removeObserver(self)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func load(queue: [AudioTrack], startIndex: Int, autoplay: Bool) {
        guard queue.indices.contains(startIndex) else {
            return
        }

        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        removePlaybackObservers()
        stopProgressUpdates()
        isPlaying = false

        self.queue = queue
        currentIndex = startIndex
        currentTrack = queue[startIndex]
        currentTime = 0
        duration = currentTrack?.duration ?? 0

        do {
            try preparePlayerForCurrentTrack()
            updateNowPlayingInfo()
            refreshCommandAvailability()

            if autoplay {
                play()
            }
        } catch {
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
            removePlaybackObservers()
            logPlaybackPreparationFailure(for: currentTrack?.fileURL, error: error)
            playbackError = error.localizedDescription
        }
    }

    func updateQueue(_ queue: [AudioTrack]) {
        self.queue = queue
        refreshCommandAvailability()

        guard let currentTrack else {
            return
        }

        if let newIndex = queue.firstIndex(of: currentTrack) {
            currentIndex = newIndex
        } else {
            stop()
        }

        refreshCommandAvailability()
    }

    func play() {
        do {
            if currentTrack == nil, let firstTrack = queue.first {
                currentIndex = 0
                currentTrack = firstTrack
            }

            guard currentTrack != nil else {
                return
            }

            try activateAudioSession()

            if player == nil {
                try preparePlayerForCurrentTrack()
            }

            guard let player else {
                playbackError = "Nao foi possivel iniciar a reproducao."
                return
            }

            if player.currentItem?.status == .failed {
                handlePlaybackFailure(player.currentItem?.error)
                return
            }

            player.play()
            isPlaying = true
            startProgressUpdates()
            updateNowPlayingInfo()
        } catch {
            logPlaybackPreparationFailure(for: currentTrack?.fileURL, error: error)
            playbackError = error.localizedDescription
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopProgressUpdates()
        refreshProgress()
        updateNowPlayingPlaybackState()
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func stop() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        removePlaybackObservers()
        isPlaying = false
        currentTrack = nil
        currentIndex = nil
        currentTime = 0
        duration = 0
        stopProgressUpdates()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        refreshCommandAvailability()
    }

    func next() {
        guard let currentIndex else {
            return
        }

        let nextIndex = currentIndex + 1
        guard queue.indices.contains(nextIndex) else {
            pause()
            seek(to: 0)
            return
        }

        load(queue: queue, startIndex: nextIndex, autoplay: isPlaying)
    }

    func previous() {
        guard let currentIndex else {
            return
        }

        if currentTime > 3 {
            seek(to: 0)
            return
        }

        let previousIndex = currentIndex - 1
        guard queue.indices.contains(previousIndex) else {
            seek(to: 0)
            return
        }

        load(queue: queue, startIndex: previousIndex, autoplay: isPlaying)
    }

    func seek(to time: TimeInterval) {
        let clampedTime = min(max(time, 0), max(duration, 0))
        player?.seek(to: CMTime(seconds: clampedTime, preferredTimescale: 600))
        currentTime = clampedTime
        updateNowPlayingPlaybackState()
    }

    private func activateAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playback,
            mode: .default,
            options: [.allowAirPlay, .allowBluetoothA2DP]
        )
        try session.setActive(true)
    }

    private func preparePlayerForCurrentTrack() throws {
        guard let currentTrack else {
            return
        }

        let fileURL = currentTrack.fileURL
        try validatePlayableLocalFile(at: fileURL)

        let playerItem = AVPlayerItem(url: fileURL)
        let avPlayer = AVPlayer(playerItem: playerItem)
        avPlayer.volume = volume
        avPlayer.actionAtItemEnd = .pause

        player = avPlayer
        observePlaybackItem(playerItem)
        duration = currentTrack.duration
    }

    private func startProgressUpdates() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshProgress()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func stopProgressUpdates() {
        progressTask?.cancel()
        progressTask = nil
    }

    private func refreshProgress() {
        guard let player else {
            return
        }

        let playerTime = player.currentTime().seconds
        if playerTime.isFinite {
            currentTime = playerTime
        }

        let itemDuration = player.currentItem?.duration.seconds
        if let itemDuration, itemDuration.isFinite, itemDuration > 0 {
            duration = itemDuration
        }

        updateNowPlayingPlaybackState()
    }

    private func observePlaybackItem(_ item: AVPlayerItem) {
        removePlaybackObservers()

        playerItemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                switch item.status {
                case .readyToPlay:
                    let itemDuration = item.duration.seconds
                    if itemDuration.isFinite, itemDuration > 0 {
                        self?.duration = itemDuration
                    }
                    self?.updateNowPlayingInfo()
                case .failed:
                    self?.handlePlaybackFailure(item.error)
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }

        playbackEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePlaybackDidFinish()
            }
        }

        playbackFailureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor [weak self] in
                self?.handlePlaybackFailure(error)
            }
        }
    }

    private func removePlaybackObservers() {
        playerItemStatusObservation?.invalidate()
        playerItemStatusObservation = nil

        if let playbackEndObserver {
            NotificationCenter.default.removeObserver(playbackEndObserver)
            self.playbackEndObserver = nil
        }

        if let playbackFailureObserver {
            NotificationCenter.default.removeObserver(playbackFailureObserver)
            self.playbackFailureObserver = nil
        }
    }

    private func handlePlaybackDidFinish() {
        if let currentIndex, queue.indices.contains(currentIndex + 1) {
            load(queue: queue, startIndex: currentIndex + 1, autoplay: true)
        } else {
            pause()
            seek(to: 0)
        }
    }

    private func handlePlaybackFailure(_ error: Error?) {
        pause()

        if let error {
            let nsError = error as NSError
            playbackError = PlaybackPreparationError.decoderRejectedFile(
                currentTrack?.fileURL,
                underlying: nsError
            ).localizedDescription
            print("[AudioPlayerManager] Playback failed: \(nsError.domain) code=\(nsError.code) \(nsError.localizedDescription)")
        } else {
            playbackError = PlaybackPreparationError.unknownDecoderFailure(currentTrack?.fileURL).localizedDescription
            print("[AudioPlayerManager] Playback failed with unknown decoder error.")
        }
    }

    private func logPlaybackPreparationFailure(for url: URL?, error: Error) {
        let nsError = error as NSError
        print(
            """
            [AudioPlayerManager] Playback preparation failed: \(url?.lastPathComponent ?? "unknown file")
            [AudioPlayerManager] Error: \(error.localizedDescription)
            [AudioPlayerManager] NSError domain=\(nsError.domain) code=\(nsError.code)
            """
        )
    }

    private func validatePlayableLocalFile(at url: URL) throws {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: url.path) else {
            throw PlaybackPreparationError.fileMissing(url)
        }

        guard fileManager.isReadableFile(atPath: url.path) else {
            throw PlaybackPreparationError.fileUnreadable(url)
        }

        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            let fileSize = attributes[.size] as? NSNumber
            guard (fileSize?.int64Value ?? 0) > 0 else {
                throw PlaybackPreparationError.emptyFile(url)
            }

            let fileHandle = try FileHandle(forReadingFrom: url)
            defer {
                try? fileHandle.close()
            }

            let sample = try fileHandle.read(upToCount: 64)
            guard sample?.isEmpty == false else {
                throw PlaybackPreparationError.emptyFile(url)
            }
        } catch let error as PlaybackPreparationError {
            throw error
        } catch {
            throw PlaybackPreparationError.readProbeFailed(url, underlying: error)
        }
    }

    private func updateNowPlayingInfo() {
        guard let currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentTrack.displayTitle,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]

        if let artist = currentTrack.artist, !artist.isEmpty {
            info[MPMediaItemPropertyArtist] = artist
        }

        if let album = currentTrack.album, !album.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = album
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        updateNowPlayingCenterPlaybackState()
    }

    private func updateNowPlayingPlaybackState() {
        guard MPNowPlayingInfoCenter.default().nowPlayingInfo != nil else {
            updateNowPlayingInfo()
            return
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        updateNowPlayingCenterPlaybackState()
    }

    private func updateNowPlayingCenterPlaybackState() {
        if #available(iOS 13.0, *) {
            MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        }
    }

    private func configureRemoteCommands() {
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)

        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.play()
            }
            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pause()
            }
            return .success
        }

        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.togglePlayPause()
            }
            return .success
        }

        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.next()
            }
            return .success
        }

        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.previous()
            }
            return .success
        }

        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }

            Task { @MainActor [weak self] in
                self?.seek(to: event.positionTime)
            }
            return .success
        }

        refreshCommandAvailability()
    }

    private func refreshCommandAvailability() {
        let hasQueue = !queue.isEmpty
        commandCenter.playCommand.isEnabled = hasQueue
        commandCenter.pauseCommand.isEnabled = hasQueue
        commandCenter.togglePlayPauseCommand.isEnabled = hasQueue
        commandCenter.nextTrackCommand.isEnabled = hasQueue
        commandCenter.previousTrackCommand.isEnabled = hasQueue
        commandCenter.changePlaybackPositionCommand.isEnabled = hasQueue
    }

    private func observeAudioSessionNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    @objc
    nonisolated private func handleInterruption(_ notification: Notification) {
        let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt

        Task { @MainActor [weak self] in
            self?.processInterruption(typeValue: typeValue, optionsValue: optionsValue)
        }
    }

    @objc
    nonisolated private func handleRouteChange(_ notification: Notification) {
        let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt

        Task { @MainActor [weak self] in
            self?.processRouteChange(reasonValue: reasonValue)
        }
    }

    private func processInterruption(typeValue: UInt?, optionsValue: UInt?) {
        guard
            let typeValue,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else {
            return
        }

        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
            pause()
        case .ended:
            guard
                wasPlayingBeforeInterruption,
                let optionsValue
            else {
                return
            }

            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                play()
            }
        @unknown default:
            break
        }
    }

    private func processRouteChange(reasonValue: UInt?) {
        guard
            let reasonValue,
            let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        else {
            return
        }

        if reason == .oldDeviceUnavailable {
            pause()
        }
    }
}

private enum PlaybackPreparationError: LocalizedError {
    case fileMissing(URL)
    case fileUnreadable(URL)
    case emptyFile(URL)
    case readProbeFailed(URL, underlying: Error)
    case decoderRejectedFile(URL?, underlying: NSError)
    case unknownDecoderFailure(URL?)

    var errorDescription: String? {
        switch self {
        case .fileMissing(let url):
            return "O arquivo \(url.lastPathComponent) nao foi encontrado no armazenamento local do app. Importe a musica novamente."
        case .fileUnreadable(let url):
            return "O arquivo \(url.lastPathComponent) existe, mas nao pode ser lido pelo app."
        case .emptyFile(let url):
            return "O arquivo \(url.lastPathComponent) esta vazio ou foi importado incompleto. Apague e importe novamente."
        case .readProbeFailed(let url, let underlying):
            let nsError = underlying as NSError
            return "Falha ao validar \(url.lastPathComponent) antes da reproducao (domain: \(nsError.domain), code: \(nsError.code))."
        case .decoderRejectedFile(let url, let underlying):
            let fileName = url?.lastPathComponent ?? "este arquivo"
            return "Nao foi possivel reproduzir \(fileName). O arquivo pode estar incompleto, corrompido ou em um formato MP3 invalido para o iOS (domain: \(underlying.domain), code: \(underlying.code))."
        case .unknownDecoderFailure(let url):
            let fileName = url?.lastPathComponent ?? "este arquivo"
            return "Nao foi possivel reproduzir \(fileName). Apague e importe novamente a partir de um arquivo baixado localmente."
        }
    }
}
