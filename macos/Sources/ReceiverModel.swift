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
                    guard let self else { return }
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
        snapshot = state; volume = Double(state.volume)
        if state.phase == .failed { error = state.message }
    }
    func start() {
        let settings = Settings(name: name, interfaceName: interfaceName, outputDevice: outputDevice, volume: UInt32(volume))
        appliedSettings = settings; wantsReceiving = true; retryCount = 0
        start(settings)
    }
    private func start(_ settings: Settings) {
        guard let receiver, !busy, !sleeping else { return }
        busy = true; error = ""
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
                DispatchQueue.main.async { [weak self] in self?.busy = false; self?.error = String(describing: error); self?.snapshot = receiver.snapshot() }
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
        backend.async { [weak self] in
            receiver.stop()
            let state = receiver.snapshot()
            DispatchQueue.main.async { [weak self] in self?.busy = false; self?.accept(state) }
        }
    }
    func setVolume() {
        guard let receiver else { return }
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
