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
        }.defaultSize(width: 760, height: 434)
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
    @Environment(\.colorScheme) private var colorScheme
    private var playing: Bool { model.snapshot?.phase == .playing }
    private var title: String {
        if let title = model.snapshot?.title, !title.isEmpty { return title }
        return model.snapshot?.controlsAvailable == true ? "手机正在投送" : "等待你的音乐"
    }
    private var artist: String {
        if let artist = model.snapshot?.artist, !artist.isEmpty { return artist }
        if model.snapshot?.controlsAvailable == true { return "来自手机的音乐" }
        return model.wantsReceiving ? "在手机妙播中选择这台 Mac" : "启动接收，让音乐在 Mac 继续"
    }
    private var footer: String {
        if !model.error.isEmpty { return model.error }
        if !model.controlMessage.isEmpty { return model.controlMessage }
        return model.wantsReceiving ? "关闭窗口后仍会继续接收" : "准备接收来自手机的音乐"
    }
    private func time(_ milliseconds: UInt64?) -> String {
        guard let milliseconds else { return "–:––" }
        let seconds = milliseconds / 1000
        return String(format: "%llu:%02llu", seconds / 60, seconds % 60)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Label("FusionPlay", systemImage: "hifispeaker.fill")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer(minLength: 20)
                    cover
                    Spacer(minLength: 20)
                    HStack(spacing: 6) {
                        Image(systemName: "iphone.radiowaves.left.and.right")
                        Text("手机投送 · Mac 接收")
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(28).frame(width: 300)
                    .background(Color.primary.opacity(colorScheme == .dark ? 0.035 : 0.025))
                Rectangle().fill(Color.primary.opacity(0.07)).frame(width: 1)
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("正在播放").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        Spacer()
                        HStack(spacing: 6) {
                            Circle().fill(playing ? Color.green : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                            Text(model.phaseLabel).font(.system(size: 11, weight: .medium))
                        }.padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.primary.opacity(0.05), in: Capsule())
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title).font(.system(size: 27, weight: .semibold))
                            .lineLimit(2).textSelection(.enabled).help(title)
                        Text(artist).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1).help(artist)
                        if let album = model.snapshot?.album, !album.isEmpty {
                            Text(album).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1).help(album)
                        }
                    }.frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
                    Spacer(minLength: 0)
                    progress
                    HStack(spacing: 26) {
                        Spacer()
                        transport("backward.end.fill", label: "上一曲") { model.control(.previous) }
                        Button { model.togglePlayback() } label: {
                            Image(systemName: playing ? "pause.fill" : "play.fill")
                                .font(.system(size: 20, weight: .semibold))
                                .offset(x: playing ? 0 : 1)
                                .frame(width: 52, height: 52)
                                .foregroundStyle(model.canControl ? Color.white : Color.secondary)
                                .background(model.canControl ? Color.accentColor : Color.primary.opacity(0.08), in: Circle())
                        }.buttonStyle(PlayerTransportStyle()).disabled(!model.canControl)
                            .help(playing ? "暂停" : "播放").accessibilityLabel(playing ? "暂停" : "播放")
                        transport("forward.end.fill", label: "下一曲") { model.control(.next) }
                        Spacer()
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "speaker.wave.2").font(.system(size: 12)).foregroundStyle(.secondary)
                        Slider(value: $model.volume, in: 0...100) { editing in if !editing { model.setVolume() } }
                            .controlSize(.small).accessibilityLabel("接收音量")
                        Text("\(Int(model.volume.rounded()))%")
                            .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                    }.disabled(!model.initialized)
                }.padding(28).frame(maxWidth: .infinity)
            }.frame(height: 380)
            Divider()
            HStack(spacing: 10) {
                Image(systemName: model.error.isEmpty ? "dot.radiowaves.left.and.right" : "exclamationmark.circle")
                    .foregroundStyle(model.error.isEmpty ? Color.secondary : Color.red)
                Text(footer).font(.system(size: 11))
                    .foregroundStyle(model.error.isEmpty ? Color.secondary : Color.red)
                    .lineLimit(2).help(footer).textSelection(.enabled)
                Spacer(minLength: 12)
                if model.wantsReceiving {
                    Button("停止接收") { model.stop() }.buttonStyle(.bordered)
                        .disabled(model.busy || !model.initialized)
                } else {
                    Button("启动接收") { model.start() }.buttonStyle(.borderedProminent)
                        .disabled(model.busy || !model.initialized)
                }
            }.controlSize(.small).padding(.horizontal, 24).frame(height: 53)
        }.frame(width: 760).background(Color(nsColor: .windowBackgroundColor))
    }
    private var cover: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(
                LinearGradient(colors: [Color.accentColor.opacity(0.16), Color.primary.opacity(0.04)],
                               startPoint: .topLeading, endPoint: .bottomTrailing))
            if let artwork = model.artwork {
                Image(nsImage: artwork).resizable().scaledToFit()
            } else {
                Circle().fill(Color.primary.opacity(0.035)).frame(width: 178, height: 178)
                ForEach([178.0, 150.0, 122.0], id: \.self) { size in
                    Circle().stroke(Color.primary.opacity(0.06), lineWidth: 1).frame(width: size, height: size)
                }
                Circle().fill(Color.accentColor.opacity(0.12)).frame(width: 72, height: 72)
                Image(systemName: "music.note").font(.system(size: 28, weight: .light))
                    .foregroundStyle(Color.accentColor.opacity(0.75))
            }
        }.frame(width: 244, height: 244).clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.06), lineWidth: 1))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.16 : 0.06), radius: 12, y: 6)
            .accessibilityLabel(model.artwork == nil ? "暂无专辑封面" : "专辑封面")
    }
    private var progress: some View {
        let duration = model.snapshot?.durationMs
        let position = model.snapshot?.positionMs
        let fraction = duration.flatMap { duration in
            position.map { duration > 0 ? min(Double($0) / Double(duration), 1) : 0 }
        } ?? 0
        return VStack(spacing: 8) {
            GeometryReader { geometry in
                Capsule().fill(Color.primary.opacity(0.09))
                Capsule().fill(Color.accentColor).frame(width: geometry.size.width * fraction)
            }.frame(height: 4).accessibilityLabel("播放进度")
                .accessibilityValue("\(time(position)) / \(time(duration))")
            HStack {
                Text(time(position)); Spacer(); Text(time(duration))
            }.font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
        }.help(duration == nil ? "手机尚未提供时长，进度随手机上报更新" : "进度随手机上报更新，暂不支持拖动")
    }
    private func transport(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16, weight: .medium)).frame(width: 32, height: 36)
                .foregroundStyle(model.canControl ? Color.primary : Color.secondary.opacity(0.4))
        }.buttonStyle(PlayerTransportStyle()).disabled(!model.canControl).help(label).accessibilityLabel(label)
    }
}

struct PlayerTransportStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
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
