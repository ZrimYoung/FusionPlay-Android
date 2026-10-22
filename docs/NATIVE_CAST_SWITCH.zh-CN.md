# 小米盒子原生投屏切换

当前方案为可恢复的临时切换。尚未解决同一 IP 上两套接收器同时运行时，手机把妙播状态和歌曲信息发给原生视频接收器的问题。

## 使用

1. 安装官方 [Shizuku](https://github.com/RikkaApps/Shizuku)，按照其界面显示的电脑启动指令启动服务。
2. 在 FusionPlay 设置中找到“暂停原生投屏”，首次操作时允许 Shizuku 授权，再次开启开关。
3. 保持 FusionPlay 在前台，重新选择手机妙播中的接收器。
4. 关闭开关或离开 FusionPlay 后，原生投屏自动恢复。无 root 的盒子重启后，需要重新启动 Shizuku。

此入口只在安装了 `com.xiaomi.hyper_connect.tv` 的设备上显示。Shizuku API 依赖要求 Android 7.0（API 24）及以上。

## 恢复机制

授权服务只执行固定目标包的停止、启动和进程检查，没有任意命令接口，也不修改包的 enabled 设置。暂停期间每两秒检查原生进程是否重新启动。

应用每五秒续约；离开前台一秒后主动恢复。应用进程死亡时通过 Binder 回调恢复；续约中断超过十五秒时也会尝试恢复。恢复失败保留待恢复状态，随后继续重试并返回错误。

该方式会暂时影响盒子原生投屏；恢复进程与端口不等于已验证所有原生投屏协议和设备组合。

## 验证

在 Android 14 的 MiTV-AZFU0 上，已验证 App 开关暂停、关闭开关恢复、返回桌面恢复，以及强制结束 FusionPlay 后恢复。恢复后原生进程和 8899 监听均重现，包仍为默认启用状态。暂停期间 FusionPlay 的妙播控制端口可连接。

用户实播确认暂停模式下除了 USB 输出外均正常；接收端日志也显示歌曲信息和进度持续被应用。该结果不代表原生与 FusionPlay 同时运行的冲突已解决，也未单独测量全屋同步误差。USB 输出仍受盒子的调试模式影响。

本轮还观察到一次冷启动报告就绪但控制端口拒绝连接，重新切换 MiPlay 后恢复；原因待查，不能将启动日志等同于端口可用。

Kotlin 测试覆盖租约过期、续约、原生进程被重新拉起、恢复失败后重试；Flutter 测试覆盖独立开关回调和切换期间禁用重复操作。

## 构建

```sh
cd flutter
flutter build apk --profile --target-platform android-arm \
  --build-name=1.2.4-castswitch --build-number=10207 \
  --dart-define=FUSIONPLAY_VERSION=1.2.4-castswitch
```

分支的 GitHub Actions 同样生成 profile APK，以避开此盒子上 debug 模式曾出现的 Flutter 无响应。
