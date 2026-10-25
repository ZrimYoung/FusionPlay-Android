import AppKit
import SwiftUI

final class ReceiverEvents: StateListener, @unchecked Sendable {
    weak var model: ReceiverModel?
    init(_ model: ReceiverModel) { self.model = model }
    func onState(state: Snapshot) {
        DispatchQueue.main.async { [weak self] in self?.model?.accept(state) }
    }
}

@MainActor
final class ReceiverModel: ObservableObject {
    static let shared = ReceiverModel()
    @Published var snapshot: Snapshot?
    @Published var name = "FusionPlay-Mac"
    @Published var interfaceName = ""
    @Published var outputDevice = ""
    @Published var volume = 50.0
    @Published var networks: [NetworkInterface] = []
    @Published var outputs: [AudioDevice] = []
    @Published var error = ""
    @Published var busy = false
    @Published var initialized = false
    @Published var wantsReceiving = false
    @Published var controlBusy = false
    @Published var controlMessage = ""
    @Published var artwork: NSImage?
    @Published var artworkStatus = "尚未连接"
    @Published var artworkLoading = false
    let root: URL
    private let backend = DispatchQueue(label: "FusionPlay.host", qos: .userInitiated)
    private var receiver: Receiver?
    private var listener: ReceiverEvents?
    private var subscription: UInt64?
    private var timer: Timer?
    private var sleeping = false
    private var signature = ""
    private var retryCount = 0
    private var appliedSettings: Settings?
    private lazy var systemMedia = SystemMediaController { [weak self] command in self?.control(command) }
    private var artworkTask: Task<Void, Never>?
    private var artworkKey = ""
    private var terminating = false

    private init() {
        root = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        let data = root.appendingPathComponent("data").path
        let marker = root.appendingPathComponent(".fusionplay-mac").path
        guard FileManager.default.fileExists(atPath: marker) else {
            error = "请从项目 artifacts 目录打开应用；未找到独立项目标记。"
            return
        }
        backend.async { [weak self] in
            do {
                let receiver = try Receiver(dataDirectory: data)
                let settings = receiver.settings()
                let networks = try networkInterfaces()
                let outputs = try audioDevices()
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.terminating else { return }
                    self.receiver = receiver
                    self.name = settings.name; self.interfaceName = settings.interfaceName
                    self.outputDevice = settings.outputDevice; self.volume = Double(settings.volume)
                    self.networks = networks; self.outputs = outputs
                    self.snapshot = receiver.snapshot()
                    let listener = ReceiverEvents(self); self.listener = listener
                    self.subscription = receiver.subscribe(listener: listener)
                    self.initialized = true
                    self.timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                        Task { @MainActor [weak self] in self?.refreshDevices() }
                    }
                    // Start once after restoring persisted settings and subscribing.
                    // Reopening a window must not override a user's explicit stop.
                    self.start()
                }
            } catch { DispatchQueue.main.async { [weak self] in self?.error = String(describing: error) } }
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.suspendForSleep() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sleeping = false
                self?.retryCount = 0
                if self?.wantsReceiving == true { self?.restartApplied() }
            }
        }
    }

    var phaseLabel: String {
        guard let phase = snapshot?.phase else { return initialized ? "未启动" : "准备中" }
        switch phase {
        case .stopped: return "未启动"
        case .starting: return "正在启动"
        case .ready: return "等待连接"
        case .connected: return "已连接"
        case .playing: return "正在播放"
        case .paused: return "已暂停"
        case .failed: return "需要处理"
        }
    }
    func accept(_ state: Snapshot) {
        guard !terminating else { return }
        snapshot = state; volume = Double(state.volume)
        if !state.controlsAvailable { controlMessage = "" }
        updateArtwork(state)
        if busy || sleeping { systemMedia.clear() }
        else { systemMedia.update(state, busy: controlBusy, artwork: artwork) }
        if state.phase == .failed { error = state.message }
    }
    var canControl: Bool { snapshot?.controlsAvailable == true && !busy && !controlBusy }
    func togglePlayback() { control(snapshot?.phase == .playing ? .pause : .play) }
    func control(_ command: PlaybackCommand) {
        guard let receiver, canControl, !terminating else { return }
        controlBusy = true; controlMessage = "正在发送到手机…"
        if let snapshot { systemMedia.update(snapshot, busy: true, artwork: artwork) }
        backend.async { [weak self] in
            do {
                let outcome = try receiver.control(command: command)
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.terminating else { return }
                    self.controlBusy = false
                    self.controlMessage = outcome.confirmed ? "手机已确认" : "指令已发送，手机尚未确认"
                    self.accept(receiver.snapshot())
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.terminating else { return }
                    self.controlBusy = false; self.controlMessage = "播放控制失败：\(error)"
                    self.accept(receiver.snapshot())
                }
            }
        }
    }
    private func updateArtwork(_ state: Snapshot) {
        let key = state.controlsAvailable ? "\(state.trackId)|\(state.artworkUrl)" : ""
        guard key != artworkKey else { return }
        artworkKey = key; artworkTask?.cancel(); artwork = nil; artworkLoading = false
        guard state.controlsAvailable else { artworkStatus = "尚未连接"; return }
        let source = state.artworkUrl
        let kind = ArtworkLoader.kind(of: source)
        guard kind != "missing" else {
            artworkStatus = "手机未提供封面"
            recordArtwork(kind: kind, result: "source_missing", attempt: 0)
            return
        }
        artworkLoading = true; artworkStatus = "正在加载封面"
        artworkTask = Task { [weak self] in
            for attempt in 1...3 {
                do {
                    let cgImage = try await ArtworkLoader.load(source)
                    guard !Task.isCancelled, let self, self.artworkKey == key, !self.terminating else { return }
                    self.artwork = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    self.artworkLoading = false; self.artworkStatus = "已加载"
                    self.recordArtwork(kind: kind, result: "loaded", attempt: attempt)
                    if let state = self.snapshot, !self.busy, !self.sleeping {
                        self.systemMedia.update(state, busy: self.controlBusy, artwork: self.artwork, force: true)
                    }
                    return
                } catch {
                    guard !Task.isCancelled, let self, self.artworkKey == key, !self.terminating else { return }
                    let known = error as? ArtworkError
                    let code = known?.diagnosticCode ?? "network_\((error as NSError).code)"
                    self.recordArtwork(kind: kind, result: code, attempt: attempt)
                    let retry = attempt < 3 && (known?.retryable ?? (error is URLError))
                    self.artworkStatus = retry ? "加载失败，正在重试" : "封面加载失败（\(code)）"
                    if !retry { self.artworkLoading = false; return }
                    do { try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000) }
                    catch { return }
                }
            }
        }
    }
    func reloadArtwork() {
        guard let snapshot, snapshot.controlsAvailable, !artworkLoading else { return }
        artworkKey = "\0"
        updateArtwork(snapshot)
        systemMedia.update(snapshot, busy: controlBusy || busy, artwork: artwork, force: true)
    }
    private func recordArtwork(kind: String, result: String, attempt: Int) {
        let directory = root.appendingPathComponent("logs")
        backend.async {
            // Only format/result/attempt are logged: no URLs, query tokens,
            // inline image bytes, track names or other phone metadata.
            let path = directory.appendingPathComponent("artwork.jsonl")
            let record: [String: Any] = ["time": Date().timeIntervalSince1970,
                                        "source_kind": kind, "result": result, "attempt": attempt]
            guard var data = try? JSONSerialization.data(withJSONObject: record) else { return }
            data.append(10)
            let fm = FileManager.default
            if let attrs = try? fm.attributesOfItem(atPath: path.path),
               let size = attrs[.size] as? NSNumber, size.intValue > 50_000 {
                let previous = directory.appendingPathComponent("artwork.previous.jsonl")
                try? fm.removeItem(at: previous); try? fm.moveItem(at: path, to: previous)
            }
            if !fm.fileExists(atPath: path.path) {
                fm.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let handle = try? FileHandle(forWritingTo: path) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data)
        }
    }
    func start() {
        guard initialized, !terminating else { return }
        let settings = Settings(name: name, interfaceName: interfaceName, outputDevice: outputDevice, volume: UInt32(volume))
        appliedSettings = settings; wantsReceiving = true; retryCount = 0
        start(settings)
    }
    private func start(_ settings: Settings) {
        guard let receiver, !busy, !sleeping, !terminating else { return }
        busy = true; error = ""
        systemMedia.clear()
        backend.async { [weak self] in
            do {
                try receiver.start(settings: settings)
                let state = receiver.snapshot()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.busy = false; self.accept(state)
                    self.signature = self.deviceSignature(settings: settings)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in self?.busy = false; self?.error = String(describing: error); self?.accept(receiver.snapshot()) }
            }
        }
    }
    func stop() {
        wantsReceiving = false
        stopCore()
    }
    private func stopCore() {
        guard let receiver else { return }
        busy = true
        systemMedia.clear()
        backend.async { [weak self] in
            receiver.stop()
            let state = receiver.snapshot()
            DispatchQueue.main.async { [weak self] in self?.busy = false; self?.accept(state) }
        }
    }
    func setVolume() {
        guard let receiver else { return }
        volume = volume.rounded()
        let value = UInt32(volume)
        backend.async { [weak self] in
            do { try receiver.setVolume(volume: value) }
            catch { DispatchQueue.main.async { [weak self] in self?.error = String(describing: error) } }
        }
    }
    func refreshDevices() {
        guard initialized, !busy, !sleeping else { return }
        backend.async { [weak self] in
            do {
                let nets = try networkInterfaces(); let audio = try audioDevices()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.networks = nets; self.outputs = audio
                    guard self.wantsReceiving, let settings = self.appliedSettings else { return }
                    let current = self.deviceSignature(settings: settings)
                    if current != self.signature {
                        self.signature = current; self.retryCount = 0
                        self.restartApplied()
                    } else if self.snapshot?.phase == .failed && self.retryCount < 3 {
                        self.retryCount += 1; self.restartApplied()
                    }
                }
            } catch { DispatchQueue.main.async { [weak self] in self?.error = "无法读取网络或音频设备：\(error)" } }
        }
    }
    private func deviceSignature(settings: Settings) -> String {
        let net = networks.first { settings.interfaceName.isEmpty || $0.name == settings.interfaceName }
        let audio = outputs.first { settings.outputDevice.isEmpty ? $0.isDefault : $0.id == settings.outputDevice }
        return "\(net?.name ?? "-")/\(net?.address ?? "-")/\(audio?.id ?? "-")"
    }
    private func restartApplied() {
        guard let appliedSettings else { return }
        start(appliedSettings)
    }
    private func suspendForSleep() {
        sleeping = true
        stopCore()
    }
    func openLogs() { NSWorkspace.shared.open(root.appendingPathComponent("logs")) }
    func terminate(completion: @escaping @MainActor @Sendable () -> Void) {
        terminating = true; artworkTask?.cancel(); systemMedia.shutdown()
        timer?.invalidate(); timer = nil; wantsReceiving = false
        // AppKit must receive the termination reply after terminateLater returns,
        // including when startup failed before a receiver was constructed.
        guard let receiver else { DispatchQueue.main.async { completion() }; return }
        let token = subscription
        backend.async {
            if let token { receiver.unsubscribe(token: token) }
            receiver.stop()
            DispatchQueue.main.async { completion() }
        }
    }
}
