import Foundation
import MediaPlayer

final class Probe: StateListener, @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0)
    func onState(state: Snapshot) { if state.phase == .ready { ready.signal() } }
}
@main
struct BridgeSmoke {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let data = root.appendingPathComponent("data")
        defer { try? FileManager.default.removeItem(at: root) }
        var receiver: Receiver? = try Receiver(dataDirectory: data.path)
        weak var released: Probe?
        do {
            let probe = Probe(); released = probe
            let token = receiver!.subscribe(listener: probe)
            try receiver!.setVolume(volume: 37)
            precondition(receiver!.settings().volume == 37)
            for command in [PlaybackCommand.play, .pause, .previous, .next] {
                do {
                    _ = try receiver!.control(command: command)
                    preconditionFailure("Disconnected receiver accepted a media command")
                } catch { /* Expected: no active phone session. */ }
            }
            var state = receiver!.snapshot()
            precondition(MediaPresentation(state) == nil)
            state.controlsAvailable = true; state.phase = .connected
            precondition(MediaPresentation(state) == nil, "Handshake must not claim Now Playing")
            state.phase = .playing; state.title = "Track"; state.artist = "Artist"
            state.durationMs = 120_000; state.positionMs = 5_000
            let presentation = MediaPresentation(state)!
            precondition(presentation.info[MPMediaItemPropertyTitle] as? String == "Track")
            precondition(presentation.position == 5 && presentation.duration == 120)
            state.queueMs = 80
            precondition(MediaPresentation(state) == presentation, "Health updates must not reset elapsed time")
            state.phase = .paused
            precondition(MediaPresentation(state)!.info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
            state.trackId = "new"; state.durationMs = nil; state.positionMs = nil
            precondition(MediaPresentation(state)!.info[MPMediaItemPropertyPlaybackDuration] == nil)
            precondition(MediaPresentation(state)!.info[MPNowPlayingInfoPropertyElapsedPlaybackTime] == nil)
            state.controlsAvailable = false
            precondition(MediaPresentation(state, previouslyActive: true) == nil)
            let gate = MediaCommandGate()
            precondition(gate.resolve(.next) == nil)
            gate.update(enabled: true, playing: true)
            precondition(gate.resolve(nil) == .pause)
            precondition(gate.resolve(nil) == nil, "Repeated media events must wait for completion")
            gate.update(enabled: true, playing: false)
            precondition(gate.resolve(nil) == .play)
            gate.update(enabled: false, playing: false)
            precondition(gate.resolve(.previous) == nil)
            if CommandLine.arguments.contains("--system-media") {
                let media = SystemMediaController { _ in }
                defer { media.shutdown() }
                state.controlsAvailable = true; state.phase = .playing
                state.title = "FusionPlay integration check"
                media.update(state, busy: false, artwork: nil)
                precondition(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == state.title)
                precondition(MPRemoteCommandCenter.shared().pauseCommand.isEnabled)
                state.phase = .paused
                media.update(state, busy: false, artwork: nil)
                precondition(MPNowPlayingInfoCenter.default().playbackState == .paused)
                state.controlsAvailable = false; state.phase = .stopped
                media.update(state, busy: false, artwork: nil)
                precondition(MPNowPlayingInfoCenter.default().nowPlayingInfo == nil)
                precondition(!MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled)
                media.shutdown() // Shutdown is idempotent and removes targets.
                print("Native MediaPlayer publication, pause and cleanup: PASS")
            }
            if CommandLine.arguments.contains("--network") {
                for _ in 0..<3 {
                    try receiver!.start(settings: receiver!.settings())
                    precondition(probe.ready.wait(timeout: .now() + 5) == .success, "Receiver did not become ready")
                    receiver!.stop()
                    precondition(receiver!.snapshot().phase == .stopped)
                }
            }
            receiver!.unsubscribe(token: token)
        }
        Thread.sleep(forTimeInterval: 0.3)
        precondition(released == nil, "Unsubscribed Swift listener leaked")
        receiver!.stop(); receiver!.stop(); receiver = nil
        let reopened = try Receiver(dataDirectory: data.path)
        precondition(reopened.settings().volume == 37)
        print("Swift/Rust bridge, media presentation/commands, subscription release, settings and lifecycle: PASS")
    }
}
