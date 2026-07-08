import AVFoundation
import Combine
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

    private var player: AVAudioPlayer?
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
        NotificationCenter.default.removeObserver(self)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func load(queue: [AudioTrack], startIndex: Int, autoplay: Bool) {
        guard queue.indices.contains(startIndex) else {
            return
        }

        player?.stop()
        player = nil
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

            guard player?.play() == true else {
                playbackError = "Nao foi possivel iniciar a reproducao."
                return
            }

            isPlaying = true
            startProgressUpdates()
            updateNowPlayingInfo()
        } catch {
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
        player?.stop()
        player = nil
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
        player?.currentTime = clampedTime
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

        let audioPlayer = try AVAudioPlayer(contentsOf: currentTrack.fileURL)
        audioPlayer.delegate = self
        audioPlayer.volume = volume
        audioPlayer.prepareToPlay()

        player = audioPlayer
        duration = audioPlayer.duration.isFinite ? audioPlayer.duration : currentTrack.duration
    }

    private func startProgressUpdates() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshProgress()
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

        currentTime = player.currentTime
        duration = player.duration.isFinite ? player.duration : duration
        updateNowPlayingPlaybackState()
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

extension AudioPlayerManager: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            if flag, let currentIndex, queue.indices.contains(currentIndex + 1) {
                load(queue: queue, startIndex: currentIndex + 1, autoplay: true)
            } else {
                pause()
                seek(to: 0)
            }
        }
    }
}
