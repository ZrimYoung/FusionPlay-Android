import Foundation

final class Probe: StateListener, @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0)
    func onState(state: Snapshot) { if state.phase == .ready { ready.signal() } }
}
@main
struct BridgeSmoke {
    static func main() throws {
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
        print("Swift/Rust bridge, subscription release, settings and lifecycle: PASS")
    }
}
