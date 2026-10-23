import AppKit
import MediaPlayer

// Only source-supplied time is published. The system extrapolates while playing;
// diagnostic snapshots must not repeatedly reset that clock to an old position.
struct MediaPresentation: Equatable {
    let title: String
    let artist: String
    let album: String
    let trackID: String
    let artworkURL: String
    let duration: Double?
    let position: Double?
    let playing: Bool

    init?(_ state: Snapshot, previouslyActive: Bool = false) {
        guard state.controlsAvailable,
              state.phase == .playing || state.phase == .paused ||
                (previouslyActive && state.phase == .connected) else { return nil }
        title = state.title.isEmpty ? "手机投送" : state.title
        artist = state.artist; album = state.album; trackID = state.trackId
        artworkURL = state.artworkUrl
        let durationSeconds = state.durationMs.map { Double($0) / 1000 }
        duration = durationSeconds
        position = state.positionMs.map { min(Double($0) / 1000, durationSeconds ?? .greatestFiniteMagnitude) }
        playing = state.phase == .playing
    }
    var info: [String: Any] {
        var result: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyAlbumTitle: album,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        if !trackID.isEmpty { result[MPNowPlayingInfoPropertyExternalContentIdentifier] = trackID }
        if let duration { result[MPMediaItemPropertyPlaybackDuration] = duration }
        if let position { result[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position }
        return result
    }
}

// Remote-command callbacks need not arrive on the main thread. Take a small
// locked snapshot, enqueue the command and return immediately; never wait for
// a phone acknowledgement on the system callback thread.
final class MediaCommandGate: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var playing = false
    func update(enabled: Bool, playing: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.enabled = enabled; self.playing = playing
    }
    func resolve(_ command: PlaybackCommand?) -> PlaybackCommand? {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return nil }
        enabled = false // Reserve one dispatch until the model reports completion.
        return command ?? (playing ? .pause : .play)
    }
}

@MainActor
final class SystemMediaController {
    private let center = MPNowPlayingInfoCenter.default()
    private let commands = MPRemoteCommandCenter.shared()
    private let gate = MediaCommandGate()
    private var targets: [(MPRemoteCommand, Any)] = []
    private var last: MediaPresentation?
    private var active = false

    init(send: @escaping @MainActor (PlaybackCommand) -> Void) {
        for (remote, action) in [
            (commands.playCommand, PlaybackCommand.play as PlaybackCommand?),
            (commands.pauseCommand, PlaybackCommand.pause as PlaybackCommand?),
            (commands.togglePlayPauseCommand, nil),
            (commands.previousTrackCommand, PlaybackCommand.previous as PlaybackCommand?),
            (commands.nextTrackCommand, PlaybackCommand.next as PlaybackCommand?)
        ] {
            let gate = self.gate
            remote.isEnabled = false
            let token = remote.addTarget { _ in
                guard let command = gate.resolve(action) else { return .noActionableNowPlayingItem }
                DispatchQueue.main.async { send(command) }
                return .success // Accepted for dispatch, not a phone-side confirmation.
            }
            targets.append((remote, token))
        }
        commands.changePlaybackPositionCommand.isEnabled = false
        commands.seekForwardCommand.isEnabled = false
        commands.seekBackwardCommand.isEnabled = false
        commands.skipForwardCommand.isEnabled = false
        commands.skipBackwardCommand.isEnabled = false
        commands.stopCommand.isEnabled = false
    }

    func update(_ state: Snapshot, busy: Bool, artwork: NSImage?, force: Bool = false) {
        let enabled = state.controlsAvailable && !busy
        gate.update(enabled: enabled, playing: state.phase == .playing)
        for (command, _) in targets { command.isEnabled = enabled }
        guard let presentation = MediaPresentation(state, previouslyActive: active) else {
            clear(); return
        }
        guard force || last != presentation else { return }
        var info = presentation.info
        if let artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
        center.nowPlayingInfo = info
        center.playbackState = presentation.playing ? .playing : .paused
        last = presentation; active = true
    }
    func clear() {
        gate.update(enabled: false, playing: false)
        for (command, _) in targets { command.isEnabled = false }
        if active { center.playbackState = .stopped; center.nowPlayingInfo = nil }
        active = false; last = nil
    }
    func shutdown() {
        clear()
        for (command, token) in targets { command.removeTarget(token) }
        targets.removeAll()
    }
}
