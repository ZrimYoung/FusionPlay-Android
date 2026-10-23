# FusionPlay Mac · 测试版

macOS 14+ / Apple Silicon。原生 SwiftUI 菜单栏界面，通过 UniFFI 调用共享 Rust MiPlay SDK，音频直接交给 macOS 输出。

## 使用

在独立项目根目录双击 `启动.command`，点击菜单栏扬声器图标，再点击“启动接收”。手机连接同一局域网，关闭影响本地通信的代理，在妙播中选择 `FusionPlay-Mac`。全屋播放由手机组织，将 Mac 与音箱一起加入即可。

首次出现局域网权限提示时允许访问。在“设置”中可以选择网卡和输出设备；默认自动选择局域网、跟随系统音频输出。修改设置后需要重新连接，手机可能需要重新选择设备。

关闭设置窗口不会停止接收。“停止接收”释放接收器；“退出”或 `停止.command` 关闭应用。不安装登录启动项，不修改全局 Python、Rust 或 shell 配置。

应用必须位于项目的 `artifacts/FusionPlay Mac.app`，旁边两级目录应有 `.fusionplay-mac` 标记。首版是独立目录安装，不要单独移动 `.app` 到 Applications。完整移动项目后应重新生成入口。

## 构建与验证

需要 Rust stable（支持 edition 2024）、Apple Command Line Tools（Swift 6 工具链）和网络访问。Swift 源码以 Swift 5 语言模式编译，以兼容 UniFFI 0.29.4；UI 使用 macOS 14 API。

```sh
bash macos/scripts/build.sh
bash macos/scripts/install-entries.sh
bash macos/scripts/test-bridge.sh
# 在有可用局域网且未运行本应用时：
bash macos/scripts/test-bridge.sh --network
python3 -m unittest discover -s macos/Tests
```

`env.sh` 优先使用相邻 Android 项目已有的工具链，依赖缓存和构建产物均写入本项目。其他机器使用 PATH 中的 Rust；可通过 `FUSIONPLAY_PROJECT_ROOT` 指定独立产物根目录。应用使用本地 ad-hoc 签名，没有 Developer ID 公证。

Rust 测试：在 bash 中加载 `macos/scripts/env.sh`，然后分别对 `src/FusionPlay.MiPlaySdk/Cargo.toml` 和 `src/FusionPlay.Host/Cargo.toml` 执行 `cargo test --locked --manifest-path …`。部分测试会绑定本地套接字，需要允许本地网络操作。

## 架构与分支兼容

- `src/FusionPlay.MiPlaySdk`：唯一共享协议核心。Mac 音频回调使用固定容量 SPSC 缓冲，保留每帧时间戳；小偏差平滑调速，严重失步先淡出再重新同步。
- `src/FusionPlay.Host`：新增类型化宿主契约与 UniFFI 适配。Swift 接收状态快照，不解析 SDK 内部 JSON。事件线程处理日志和 UI 订阅，音频线程不调用 Swift。
- `macos`：原生 UI、打包及清理入口。Android Flutter/Kotlin/JNI 保留原实现。

平台修复以 `target_os = "macos"` 隔离。共享 Lyra 生命周期修复单独提交，供 Android 分支独立合入。基线与分支见 `BASELINE.md`。不复制核心、不重命名现有 Android 工程、不修改其包名或校准值。

## 诊断及实播验收

日志在项目 `logs/receiver.jsonl`，单文件约 5 MB 轮换一次，只保留当前与上一份。记录缓冲量、输出延迟、调度误差、欠载、丢帧和重新同步计数；不保存认证材料、原始包、封面或曲目信息。设备身份和设置在 `data`，目录权限 700，文件 600。

先以 Mac 内置扬声器验证：发现、连接、播放/暂停、重连、加入/退出全屋，然后连续播放至少 30 分钟。观察是否有毛刺、断音或随时间扩大的偏差。启动对齐产生的丢帧与持续播放期间的异常需要分别判断。

20 ms 是工程目标，必须用同一录音中的瞬态信号测量；菜单栏“调度误差”不等于声学同步偏差。只取得听感反馈时标记“主观通过，客观偏差未测”。蓝牙音频设备不属于首版同步验收对象。

网络或输出设备变化会触发受控重连；失败最多自动重试三次。睡眠时停止，唤醒后恢复用户此前请求的接收状态。手机可能需要重新选择设备。实际睡眠、网络切换及输出切换仍需逐项实测记录。

实播中断或未完成不能宣称毛刺已修复。详见 `VALIDATION.md`。

## 清理

双击根目录 `清理.command`，查看范围并输入 `DELETE`。清理程序会请求本应用退出，确认没有本项目接收进程后，删除 `artifacts/build/cache/data/logs/tmp`，包括本项目设备身份。保留 `source` 中的源码、提交历史及根目录入口。

只查看范围：`python3 macos/scripts/cleanup.py`。清理逻辑在临时目录中测试，包括拒绝无标记目录、保留源码和不跟随目录符号链接。

如需彻底移除项目，先确认代码已推送，再在 Finder 删除独立项目根目录。现有 MiXPlay、Android 项目及共享工具不会被清理脚本删除。macOS 自身维护的隐私授权、启动记录不由本脚本删除。

项目继承 AGPL-3.0-only 许可证；分发应用时应同时提供对应源码与许可证。
