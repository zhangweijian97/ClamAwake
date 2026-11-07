# ClamAwake — macOS 合盖保活工具

**简体中文** | [English](README.en.md)

合盖之后，机器照常运行 AI / 长任务，屏幕熄灭。

## 解决什么问题

MacBook 合上盖子，macOS 默认直接进入睡眠——正在跑的 AI 任务、编译、下载全部中断。想让机器继续跑，让显示器睡眠也不行：屏幕一熄，截屏类的视觉采集拿到的就是纯黑画面。

ClamAwake 的做法：给系统接一块自建的虚拟屏，合盖后由虚拟屏接管显示、屏幕熄灭——机器照常跑，视觉采集不受影响。

## 原理

核心是 macOS 的私有 `CGVirtualDisplay` 类族。这些类没有公开头文件，ClamAwake 用 `NSClassFromString` 取类、`objc_msgSend` 做消息派发，按每个方法的真实 ABI 强转函数指针来调用（Swift 无法给运行时注册的私有 ObjC 类写 extension）。私有类族没有 destroy API——虚拟屏的生命周期等于创建它的进程的生命周期，引擎用 `--hold` 前台常驻来持有屏幕。

合盖侧配合 `caffeinate -d` 显示断言（完整配方见下文）。另外，若你的机型合盖后仍会入睡，需要系统级禁睡：`pmset` 的 `SleepDisabled` 项（需 sudo），工具不代用户设置。

## 当前形态

目前发布的是 CLI 源码形态：

- `vd-engine` — 虚拟屏引擎（创建 / 查询虚拟屏）
- `mirror-probe` — 显示器镜像工具（虚拟屏与内屏建立 / 解除镜像）

菜单栏常驻壳与 DMG 打包在路线图上，是下一站。

## 构建

需要 Xcode Command Line Tools（提供 swiftc）。

```sh
swiftc -O src/vd-engine.swift -o vd-engine
swiftc -O src/mirror-probe.swift -o mirror-probe
```

## 使用

不带参数运行 `vd-engine` 或 `mirror-probe` 会打印 usage；以下说明与之一致，以程序输出为准。

### vd-engine

```text
用法:
  vd-engine create <W> <H> [--hidpi] [--hold]   建虚拟屏（逻辑分辨率 WxH），成功后 stdout 打印屏 id
  vd-engine remove <id>                          销毁指定虚拟屏
  vd-engine list                                 列出全部在线显示器（只读）
  vd-engine hi <id>                              打印指定屏的 HiDPI 情况（只读）

选项:
  --hidpi  逻辑 WxH、像素 2Wx2H（例: 1800 1169 --hidpi → 像素 3600x2338，HiDPI 档进模式列表）
  --hold   建完不退出，前台常驻持有该屏（Ctrl-C / SIGTERM 结束，屏随之销毁）

退出码: 0 成功 / 1 运行错 / 2 用法错
```

`remove` 是有意「不静默失败」的：跨进程没有销毁 API，它面对的必然是别的进程持有的屏，程序会把真正可行的销毁办法讲清楚。

### mirror-probe

```text
用法:
  mirror-probe mirror   <internalID> <virtualID>   虚拟屏(virtualID/slave)镜像内屏(internalID/master)
  mirror-probe unmirror <virtualID>                解除 virtualID 的镜像关系
  mirror-probe status   <displayID>                打印 CGDisplayMirrorsDisplay 读数（只读无副作用）
```

### 合盖保活配方

```sh
vd-engine create 1800 1169 --hidpi --hold &
caffeinate -d &
```

之后合盖：屏幕熄灭，机器继续运行，视觉采集不受影响。解除时结束引擎进程（Ctrl-C 或 `kill`），再跑 `caffeinate -u -t 3` 唤醒显示器。

## 致谢

- [pasky/hidpi-mirror](https://github.com/pasky/hidpi-mirror)
- [xtongs/mirrorscreen](https://github.com/xtongs/mirrorscreen)

两者均为 MIT 许可，是本项目构建虚拟屏的参考实现——只参考了私有 API 的调用形态，未复用代码。

## 许可证

[GPL-3.0](LICENSE)

## 赞赏

如果 ClamAwake 帮到了你，请作者喝杯咖啡：[爱发电](https://afdian.net/a/<待填>)

## 署名

ClamAwake is maintained by @<待填GitHub ID>.
