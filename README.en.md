# ClamAwake — macOS Lid-Closed Keep-Alive Tool

[简体中文](README.md) | **English**

With the lid closed, the machine keeps running AI tasks and long jobs — and the screen stays off.

## The problem

Close a MacBook's lid and macOS goes to sleep by default — AI tasks, builds, downloads, all interrupted. Keeping the machine awake with the display asleep doesn't work either: once the screen goes dark, screenshot-based visual capture gets a pure black frame.

ClamAwake's approach: attach a self-created virtual display to the system. After the lid closes, the virtual display takes over and the real screen goes dark — the machine keeps running, and visual capture is unaffected.

## How it works

The core is macOS's private `CGVirtualDisplay` class family. These classes have no public headers, so ClamAwake resolves them with `NSClassFromString`, dispatches messages through `objc_msgSend`, and casts function pointers according to each method's real ABI (Swift cannot declare extensions on private ObjC classes registered at runtime). The private class family has no destroy API — a virtual display's lifetime equals that of the process that created it, so the engine holds the display with a foreground `--hold` mode.

On the lid side, a `caffeinate -d` display assertion is used (full recipe below). Additionally, if your machine still falls asleep with the lid closed, you need a system-level sleep disable: the `SleepDisabled` flag in `pmset` (requires sudo) — the tool never sets it on the user's behalf.

## Current state

What is published today is the CLI source form:

- `vd-engine` — the virtual display engine (create / inspect virtual displays)
- `mirror-probe` — the display mirroring tool (create / remove mirrors between the virtual display and the built-in display)

A menu bar shell and DMG packaging are on the roadmap — that's the next stop.

## Build

Requires Xcode Command Line Tools (provides swiftc).

```sh
swiftc -O src/vd-engine.swift -o vd-engine
swiftc -O src/mirror-probe.swift -o mirror-probe
```

## Usage

Running `vd-engine` or `mirror-probe` without arguments prints its usage; the notes below match it, and the program's own output is authoritative.

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

`remove` deliberately never fails silently: there is no cross-process destroy API, so the display you target is always held by another process — the tool explains what would actually destroy it.

### mirror-probe

```text
用法:
  mirror-probe mirror   <internalID> <virtualID>   虚拟屏(virtualID/slave)镜像内屏(internalID/master)
  mirror-probe unmirror <virtualID>                解除 virtualID 的镜像关系
  mirror-probe status   <displayID>                打印 CGDisplayMirrorsDisplay 读数（只读无副作用）
```

### The lid-closed keep-alive recipe

```sh
vd-engine create 1800 1169 --hidpi --hold &
caffeinate -d &
```

Then close the lid: the screen goes dark, the machine keeps running, and visual capture is unaffected. To undo, stop the engine process (Ctrl-C or `kill`), then run `caffeinate -u -t 3` to wake the display.

## Acknowledgments

- [pasky/hidpi-mirror](https://github.com/pasky/hidpi-mirror)
- [xtongs/mirrorscreen](https://github.com/xtongs/mirrorscreen)

Both are MIT-licensed and served as reference implementations for building virtual displays — only the calling shapes of the private APIs were studied, no code was reused.

## License

[GPL-3.0](LICENSE)

## Support

If ClamAwake has been useful to you, buy the author a coffee: [Aifadian](https://afdian.net/a/<待填>)

## Maintainer

ClamAwake is maintained by @<待填GitHub ID>.
