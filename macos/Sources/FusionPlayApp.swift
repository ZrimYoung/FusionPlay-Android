import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let duplicates = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        if duplicates.count > 1 { NSApp.terminate(nil) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ReceiverModel.shared.terminate { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

@main
struct FusionPlayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = ReceiverModel.shared
    var body: some Scene {
        MenuBarExtra("FusionPlay", systemImage: model.snapshot?.phase == .playing ? "hifispeaker.fill" : "hifispeaker") {
            ReceiverPanel(model: model)
        }.menuBarExtraStyle(.window)
        Window("FusionPlay · 正在播放", id: "player") {
            PlayerView(model: model)
        }.defaultSize(width: 400, height: 560)
          .windowResizability(.contentSize)
        Window("FusionPlay 设置", id: "settings") {
            SettingsPanel(model: model)
        }.defaultSize(width: 480, height: 430)
          .windowResizability(.contentSize)
    }
}

struct ReceiverPanel: View {
    @ObservedObject var model: ReceiverModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "hifispeaker.fill").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading) { Text("FusionPlay").font(.headline); Text("Mac 接收器 · 测试版").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Circle().fill(model.snapshot?.phase == .playing ? .green : .secondary).frame(width: 8, height: 8)
            }
            Text(model.phaseLabel).font(.title3.weight(.semibold))
            Text(model.snapshot?.message ?? "正在准备接收器").font(.caption).foregroundStyle(.secondary)
            if let state = model.snapshot, !state.title.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.title).font(.headline).lineLimit(2)
                    Text(state.artist).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            PlaybackControls(model: model)
            if !model.controlMessage.isEmpty {
                Text(model.controlMessage).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Image(systemName: "speaker.wave.2")
                Slider(value: $model.volume, in: 0...100) { editing in if !editing { model.setVolume() } }
                Text("\(Int(model.volume.rounded()))%").monospacedDigit().frame(width: 42)
            }.disabled(!model.initialized)
            if !model.error.isEmpty {
                Text(model.error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            Button(model.wantsReceiving ? "停止接收" : "启动接收") {
                if model.wantsReceiving { model.stop() } else { model.start() }
            }.buttonStyle(.borderedProminent).disabled(model.busy || !model.initialized)
            Divider()
            HStack {
                Button("正在播放") { openWindow(id: "player"); NSApp.activate(ignoringOtherApps: true) }
                Button("设置…") { openWindow(id: "settings"); NSApp.activate(ignoringOtherApps: true) }
                Button("日志") { model.openLogs() }
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
            }.buttonStyle(.borderless)
        }.padding(18).frame(width: 320)
    }
}

struct PlaybackControls: View {
    @ObservedObject var model: ReceiverModel
    var body: some View {
        HStack(spacing: 26) {
            Spacer()
            Button { model.control(.previous) } label: { Image(systemName: "backward.end.fill") }
                .help("上一曲").accessibilityLabel("上一曲")
            Button { model.togglePlayback() } label: {
                Image(systemName: model.snapshot?.phase == .playing ? "pause.fill" : "play.fill")
                    .font(.title2).frame(width: 32, height: 32)
            }.help(model.snapshot?.phase == .playing ? "暂停" : "播放")
                .accessibilityLabel(model.snapshot?.phase == .playing ? "暂停" : "播放")
            Button { model.control(.next) } label: { Image(systemName: "forward.end.fill") }
                .help("下一曲").accessibilityLabel("下一曲")
            Spacer()
        }.buttonStyle(.borderless).disabled(!model.canControl)
    }
}

struct PlayerView: View {
    @ObservedObject var model: ReceiverModel
    private func time(_ milliseconds: UInt64) -> String {
        let seconds = milliseconds / 1000
        return String(format: "%llu:%02llu", seconds / 60, seconds % 60)
    }
    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Label("FusionPlay", systemImage: "hifispeaker.fill").font(.headline)
                Spacer()
                Text(model.phaseLabel).font(.caption).foregroundStyle(.secondary)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(.quaternary)
                if let artwork = model.artwork {
                    Image(nsImage: artwork).resizable().scaledToFit()
                } else {
                    Image(systemName: "music.note").font(.system(size: 70, weight: .light))
                        .foregroundStyle(.secondary).accessibilityLabel("暂无封面")
                }
            }.frame(width: 230, height: 230).clipShape(RoundedRectangle(cornerRadius: 16))
            VStack(spacing: 5) {
                Text(model.snapshot?.title.isEmpty == false ? model.snapshot!.title : "等待手机投送")
                    .font(.title2.weight(.semibold)).lineLimit(2).textSelection(.enabled)
                if let state = model.snapshot {
                    Text([state.artist, state.album].filter { !$0.isEmpty }.joined(separator: " · "))
                        .foregroundStyle(.secondary).lineLimit(2)
                }
            }.frame(maxWidth: .infinity)
            if let state = model.snapshot, let duration = state.durationMs, duration > 0 {
                VStack(spacing: 5) {
                    if let position = state.positionMs {
                        ProgressView(value: Double(min(position, duration)), total: Double(duration))
                        HStack { Text(time(position)); Spacer(); Text(time(duration)) }
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    } else { Text("总时长 \(time(duration)) · 手机未提供播放位置").font(.caption).foregroundStyle(.secondary) }
                }
            } else {
                Text("手机尚未提供时长和进度").font(.caption).foregroundStyle(.secondary)
            }
            PlaybackControls(model: model)
            HStack {
                Image(systemName: "speaker.wave.2")
                Slider(value: $model.volume, in: 0...100) { editing in if !editing { model.setVolume() } }
                Text("\(Int(model.volume.rounded()))%").monospacedDigit().frame(width: 42)
            }.disabled(!model.initialized)
            Text(model.controlMessage.isEmpty ? (model.snapshot?.message ?? "准备中") : model.controlMessage)
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if !model.error.isEmpty { Text(model.error).font(.caption).foregroundStyle(.red) }
            Button(model.wantsReceiving ? "停止接收" : "启动接收") {
                if model.wantsReceiving { model.stop() } else { model.start() }
            }.disabled(model.busy || !model.initialized)
        }.padding(24).frame(width: 360)
    }
}

struct SettingsPanel: View {
    @ObservedObject var model: ReceiverModel
    var body: some View {
        Form {
            Section("接收设置") {
                TextField("设备名称", text: $model.name)
                Picker("网络接口", selection: $model.interfaceName) {
                    Text("自动选择局域网").tag("")
                    ForEach(model.networks, id: \.address) { item in Text("\(item.name) · \(item.address)").tag(item.name) }
                    if !model.interfaceName.isEmpty && !model.networks.contains(where: { $0.name == model.interfaceName }) {
                        Text("\(model.interfaceName)（不可用）").tag(model.interfaceName)
                    }
                }
                Picker("声音输出", selection: $model.outputDevice) {
                    Text("跟随系统输出").tag("")
                    ForEach(model.outputs, id: \.id) { item in Text(item.name).tag(item.id) }
                    if !model.outputDevice.isEmpty && !model.outputs.contains(where: { $0.id == model.outputDevice }) {
                        Text("所选设备已断开").tag(model.outputDevice)
                    }
                }
                Button(model.wantsReceiving ? "保存并重新连接" : "保存并启动接收") { model.start() }
                    .disabled(model.busy || !model.initialized)
                Text("重新连接后，可能需要在手机上重新选择此设备。全屋播放请在手机中添加 Mac。").font(.caption).foregroundStyle(.secondary)
            }
            Section("同步诊断") {
                LabeledContent("状态", value: model.phaseLabel)
                if let s = model.snapshot {
                    LabeledContent("输出设备", value: s.output.isEmpty ? "尚未输出" : s.output)
                    LabeledContent("音频缓冲", value: String(format: "%.1f ms", s.queueMs))
                    LabeledContent("设备输出延迟", value: String(format: "%.1f ms", s.outputLatencyMs))
                    LabeledContent("调度误差", value: String(format: "%.1f ms", s.scheduleErrorMs))
                    LabeledContent("欠载 / 重新同步", value: "\(s.underruns) / \(s.resyncs)")
                }
                Text("调度误差是软件内部指标，不代表与其他音箱的实测声音偏差。").font(.caption).foregroundStyle(.secondary)
            }
            if !model.error.isEmpty { Text(model.error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }.formStyle(.grouped).frame(width: 480).padding(8)
    }
}
