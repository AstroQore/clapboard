# Clapboard

> 本文档是 [README.md](README.md) 的中文翻译，结构与其保持一致。如有出入，以英文版为准。

Clapboard 是一款原生 macOS 混音器，面向同时用多支麦克风录音的人。它会捕获你接入的每一个
USB / 无线接收器和虚拟设备（Loopback、Audio Hijack），把每一路信号都送进一条 lane——
增益、开关、延迟、可选的 Audio Unit 效果器——再把它们相加，送到一个输出设备。

它存在的理由是 **Auto Sync**：无线麦克风会带来 20–100 ms 的延迟，而 macOS 从不上报这个
延迟，于是多路麦克风混音会逐渐错位。按下 Auto Sync，拍一下手，Clapboard 就会测出这次拍手
到达每条 lane 的时间，并把补偿延迟写回每一条 lane。

## 状态

| 里程碑 | 状态 |
|---|---|
| M0 脚手架、设备列表、热插拔 | 已完成 |
| M1 多设备采集 + 混音 + 输出（私有聚合设备、HAL IOProc） | 已完成 |
| M2 每条 lane 的增益 / 开关 / 延迟 / 极性，电平表 | 已完成 |
| M3 Auto Sync（起始点检测 + 带限 GCC-PHAT、结果表、校验） | 已完成 —— 真实拍手场景下的声学精度仍待确认 |
| M4 带延迟补偿的 Audio Unit 宿主 | 进行中 |
| M5 会话持久化、缺失设备处理 | 已完成 |

## 安装与更新

从 [最新 release][releases] 下载 `.zip`，解压后把 `Clapboard.app` 拖进 `/Applications`。

Clapboard 是 **ad-hoc 签名、未经公证（notarize）** 的——这个项目背后没有 Apple Developer
Program 会员——所以第一次打开必须**右键 › 打开**（或者到「系统设置 › 隐私与安全性」里放行）。
直接双击会被 Gatekeeper 拦下。release 页面上和安装包并排的 `.sha256` 可以用来核对下载内容。

### 更新

Clapboard 通过 [Sparkle][sparkle] 自更新，有两条通道：

| | |
|---|---|
| **Main** | 只有稳定版——默认 |
| **Dev** | 预览版**加上**所有 Main 版本 |

在 **Clapboard › Update Channel** 里选择通道，用 **Clapboard › Check for Updates…**
手动检查。Clapboard 每天检查一次，安装前一定会先问，并且从不后台静默安装——混音器不能在
一场直播进行到一半时把自己换掉。

每个更新包都用 EdDSA 密钥签名，并且在**解压之前**就完成验证，这正是一个未公证的下载仍然
可以放心接受的原因。公钥放在 `Resources/Info.plist` 里；私钥从不进入这个仓库。完整流程见
`RELEASING.md`。

**只要构建还是 ad-hoc 签名，就有一个绕不开的粗糙之处：** ad-hoc 签名是由二进制自身的哈希
推导出来的，所以在 macOS 看来每次更新都是一个不同的 app。请预期**更新之后麦克风授权提示会
重新弹出**——如果它没有弹出、而电平表却一直是静音，那说明 macOS 里留着一条旧的「已拒绝」
记录：执行 `tccutil reset Microphone com.astroqore.Clapboard` 后重新启动。原因见
`docs/PERMISSIONS.md`。

[releases]: https://github.com/AstroQore/clapboard/releases
[sparkle]: https://sparkle-project.org

## 构建

需要 macOS 26 和 Xcode 26（Swift 6.2）。纯 SwiftPM 项目，只有一个依赖：[Sparkle][sparkle]，
锁定在一个确切版本，由 `Scripts/build_app.sh` 嵌入 bundle 并在 app 之前完成签名。

```sh
swift build
swift test
./Scripts/build_app.sh release        # -> .build/Clapboard.app
open .build/Clapboard.app
```

`.build/Clapboard.app/Contents/MacOS/Clapboard --list-devices` 会打印 app 看到的每一个
Core Audio 设备然后退出，方便写脚本调用。

`--engine-test <seconds>` 会以无界面方式运行引擎，每秒打印一行——回调计数、过载计数、
watchdog 存活时间和每一路电平表——这样整条采集链路都能用脚本检查：

```sh
.build/Clapboard.app/Contents/MacOS/Clapboard --engine-test 120 \
    --output "Loopback" --lane "MacBook Pro Microphone" --lane "Audio Hijack Input" \
    --rebuild-at 20 --hot-lane "Mic Mix"
```

如果聚合设备在拆除后仍然存在，它会以非零状态退出。在还没有回应过麦克风授权提示的机器上，
加上 `--ignore-tcc` 可以在跳过真实采集的前提下测试其余部分。

务必运行 `.app`，不要用 `swift run`：麦克风权限是授予 bundle identifier 的，裸可执行文件
没有这个标识。

## 会话文件

Clapboard 把混音器状态记在
`~/Library/Application Support/Clapboard/session.json` 里：每条 lane（设备 UID、声道、
名称、增益、开关、极性、延迟——以及它们的顺序）、输出设备、主增益。电平表和运行状态不在
其中。

它会在最后一次改动一秒后写入，退出前和睡眠前也会再写一次，所以拖一次推子只产生一次写入，
而不是六十次。写入是原子的——先写到同目录下的临时文件，再覆盖旧文件——所以崩溃或者磁盘写满
只会留下截断的临时文件，而不是损坏正式的会话文件本身。解析失败的文件永远不会被丢弃：它会
被重命名为 `session.json.corrupt-<timestamp>`，失败信息会被上报，随后 app 以空会话启动。

设备没插上的 lane 会被**原样保留**。它会报告 `deviceMissing`，混音的其余部分照常运行，
设备重新插上时它会自动重新绑定。Lane id 在重启之间保持不变，所以任何依赖它的东西——M3
测出的延迟、M4 的插件状态——都会一直挂在正确的 lane 上。

这个格式刻意做得很宽容，因为会话文件的寿命会超过写出它的那个构建版本，也可能被手工编辑：
未知的键会被忽略，缺失的字段回退到和内存中类型一致的默认值，一条无法解码的 lane 不会连累
其它 lane，来自更新版本 Clapboard 的 `formatVersion` 只会被上报，而不会被拒绝。

无界面命令：

```sh
Clapboard --session-dump                       # 打印当前会话文件
Clapboard --engine-test 5 --output "Loopback" --lane "MacBook Pro Microphone" \
    --save-session --session-path /tmp/session.json
Clapboard --restore-session /tmp/session.json --run 5
```

`--restore-session` 会把一个文件载入一个全新的引擎，打印它拿回的 lane——包括哪些 lane
指向的设备现在不在——然后运行引擎几秒钟，所以 lane 状态是实测出来的，而不是假设出来的。

## 无界面命令

这个可执行文件同时也是一个命令行工具。这些标志位在 `main.swift` 里，会在 AppKit 启动之前
被派发，所以它们可以从 shell 里直接跑，也不会打开任何窗口：

```sh
BIN=.build/Clapboard.app/Contents/MacOS/Clapboard
$BIN --list-devices
$BIN --engine-test 20 --output Loopback --lane "MacBook Pro Microphone" --lane "Audio Hijack Input" --rebuild-at 8 --hot-lane "BlackHole 2ch"
$BIN --sync-test 8 --output Loopback --lane "Wireless Mic Rx" --lane "MacBook Pro Microphone" --apply   # 提示 CLAP NOW 时拍一下手
$BIN --engine-test 5 --output Loopback --lane "MacBook Pro Microphone" --save-session --session-path /tmp/s.json
$BIN --restore-session /tmp/s.json --run 3
$BIN --session-dump
$BIN --session-autosave-test
```

每种模式退出时都会销毁自己的私有聚合设备，包括收到 SIGTERM / SIGINT（`pkill`、Ctrl-C）
的情况。不要用 `kill -9` 结束一个正在运行的实例：一个带着已注册聚合设备死掉的进程，会让
coreaudiod 无法接受新客户端，直到它被重启（`sudo killall coreaudiod`）。

## 麦克风权限与代码签名

`build_app.sh` 默认使用 ad-hoc 签名。ad-hoc 签名的 designated requirement 就是二进制
本身的哈希，所以 macOS 会把**每一次重新构建都当成一个不同的 app**：麦克风授权提示会
重新弹出，或者授权被静默拒绝，引擎因此只能采集到静音。

两种解决办法：

1. 在钥匙串访问里创建一个自签名的 *Code Signing* 证书（证书助理 › 创建证书…，类型选
   "Code Signing"），然后用它构建：

   ```sh
   CLAPBOARD_CODESIGN_IDENTITY="Your Certificate Name" ./Scripts/build_app.sh release
   ```

   这个身份在多次重新构建之间保持稳定，权限也会一直保留。

2. 每次重新构建后重置权限：

   ```sh
   tccutil reset Microphone com.astroqore.Clapboard
   ```

这个 app 是刻意不做沙盒、也不启用 hardened runtime 的：它需要在进程内宿主第三方 AUv2
插件，而 library validation 会阻止这件事。`Resources/Clapboard.entitlements` 是刻意
留空的。（Sparkle 自己的辅助可执行文件**确实**启用了 hardened runtime——它们是独立的
二进制，永远不会宿主插件。）

正式发布的构建同样是 ad-hoc 签名的，这也是为什么一次应用内更新会重新索取麦克风权限；
见上面的「安装与更新」和 `RELEASING.md`。

## 目录结构

```
Package.swift                 ClapboardApp (SwiftUI) · ClapboardCore (engine) · ClapboardCoreTests
Sources/ClapboardCore/Audio   Core Audio 封装、设备注册表、聚合设备声道布局
Sources/ClapboardCore/RT      实时渲染内核、延迟线、电平表                     (M1+)
Sources/ClapboardCore/Sync    起始点检测、GCC-PHAT、拍手对齐器                 (M3)
Sources/ClapboardCore/AU      Audio Unit 目录与宿主                          (M4)
Sources/ClapboardCore/Session JSON 会话文档                                  (M5)
Sources/ClapboardApp          app 入口、控制器、视图
Sources/ClapboardApp/AppUpdateController.swift  Sparkle 更新器与通道选择
Scripts/build_app.sh          打包 + 签名 .build/Clapboard.app（含 Sparkle）
Scripts/release_app.sh        为一个 tag 生成 zip + 校验和 + 已签名的 appcast 条目
Scripts/generate_update_feed.sh  重建双通道共享 appcast
```

## 状态、贡献与许可

实现进度见上面的状态表；`docs/ARCHITECTURE.md` 会明确标出计划中但尚未实现的部分
（总线路由、快捷键、虚拟设备驱动、进程音频抓取），这样这份 README 就不需要跟代码反复
核对才知道哪些是真的。

**虚拟设备驱动仍在计划中，尚未实现。** 它上线后会在系统级的
`/Library/Audio/Plug-Ins/HAL` 下安装一个 HAL 插件，需要管理员权限——详见
`docs/PERMISSIONS.md`。

欢迎贡献——构建/测试/打包验证步骤、实时音频规则和 PR 检查清单见 `CONTRIBUTING.md`。
也请阅读 `CODE_OF_CONDUCT.md`；涉及安全问题的内容见 `SECURITY.md`。

## 许可证

AGPL-3.0-only。完整文本见 `LICENSE`；本项目依赖的内容见 `THIRD_PARTY_NOTICES.md`
——Sparkle（MIT），它会被一并打进 app bundle 里；除此之外没有 Apple 系统框架以外的依赖。
