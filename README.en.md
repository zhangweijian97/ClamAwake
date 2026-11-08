# ClamAwake — macOS Lid-Closed Keep-Alive Tool

[简体中文](README.md) | **English**

With the lid closed, the machine keeps running AI tasks and long jobs — and the screen stays off.

## The problem

Close a MacBook's lid and macOS goes to sleep by default — AI tasks, builds, downloads, all interrupted. Keeping the machine awake with the display asleep doesn't work either: once the screen goes dark, screenshot-based visual capture gets a pure black frame.

ClamAwake's approach: attach a self-created virtual display to the system. After the lid closes, the virtual display takes over and the real screen goes dark — the machine keeps running, and visual capture is unaffected.

## How it works

The core is macOS's private `CGVirtualDisplay` class family. These classes have no public headers, so ClamAwake resolves them with `NSClassFromString`, dispatches messages through `objc_msgSend`, and casts function pointers according to each method's real ABI (Swift cannot declare extensions on private ObjC classes registered at runtime). The private class family has no destroy API — a virtual display's lifetime equals that of the process that created it, so the engine holds the display with a foreground `--hold` mode.

On the lid side, a `caffeinate -d` display assertion is used (full recipe below). Additionally, if your machine still falls asleep with the lid closed, you need a system-level sleep disable: the `SleepDisabled` flag in `pmset` (requires sudo) — the tool never sets it on the user's behalf. `vd-engine doctor` reads this flag and prints the exact command when sleep is not disabled (see [First run](#first-run)).

## Current state

Two forms ship today:

- `vd-engine` — the virtual display engine (create / inspect virtual displays, plus a `doctor` environment self-check)
- `mirror-probe` — the display mirroring tool (create / remove mirrors between the virtual display and the built-in display)
- Menu bar shell (`shell/`) — a SwiftUI menu bar app: keep-alive toggle, status display, login item (SMAppService), system-level sleep guard (first use pops an admin authorization dialog once; no terminal required)

Build & package: `scripts/make-dmg.sh` produces `dist/ClamAwake.dmg` in one command (ad-hoc unsigned; double-click to install).

## First run

Prerequisites: macOS with [Xcode Command Line Tools](https://developer.apple.com/xcode/features/) (provides swiftc; if missing, run `xcode-select --install`).

### Step 1: Build

```sh
swiftc -O src/vd-engine.swift -o vd-engine
swiftc -O src/mirror-probe.swift -o mirror-probe
```

No output from either command means success — the directory now contains the two executables `vd-engine` and `mirror-probe`.

### Step 2: Environment self-check

```sh
./vd-engine doctor
```

stdout carries one check per line (`check=… result=…`); advice and warnings go to stderr. All five checks pass and exit code 0 means the environment is ready:

```text
check=private_class result=pass detail=CGVirtualDisplay available
check=caffeinate result=pass detail=/usr/bin/caffeinate present
check=displays result=pass detail=2 display(s) online, 1 builtin
check=keepalive_running result=pass detail=no vd-engine pid; no kya display; no caffeinate assertion
check=lid_sleep result=pass detail=SleepDisabled=1 (lid-close sleep disabled)
```

Two lines deserve attention (a warn doesn't block, but read the advice on stderr):

- `lid_sleep` warn → the machine will sleep when the lid closes. Disable it with the exact command printed on stderr: `sudo pmset -a disablesleep 1` (revert with `sudo pmset -a disablesleep 0`).
- `keepalive_running` warn → a keep-alive is already running (engine process / kya-marked display / caffeinate assertion). Follow the stderr advice: reuse it, or end it with `kill -TERM <pid>` first.

### Step 3: Start the engine (foreground; keep this terminal open)

```sh
./vd-engine create 1800 1169 --hidpi --hold
```

What happens: a virtual display of 1800×1169 (pixels 3600×2338) is attached to the system; stdout prints its display id (e.g. `22`), stderr prints diagnostics; the process then stays in the foreground holding that display — **Ctrl-C or closing the terminal destroys it**.

(1800 1169 is the logical resolution of a typical MacBook panel; `--hidpi` doubles the pixels into the HiDPI tier. `1920 1080` works fine too.)

### Step 4: Close the lid

In another terminal:

```sh
caffeinate -d &
```

Then close the lid: the screen goes dark, the machine keeps running, and visual capture gets the virtual display's frame instead of black.

(Without sleep disabled and without the "external display + power" clamshell condition, closing the lid puts the machine to sleep — which is exactly what Step 2 handles.)

### (Optional) Mirror the virtual display onto the built-in display

For visual capture that needs "the same picture as the current session":

```sh
./mirror-probe mirror 1 22     # 1 = built-in display id (main=yes in vd-engine list), 22 = virtual display id
# stdout: mirrored
./mirror-probe status 22       # read-back verification: prints 1 (the built-in id); 0 when not mirrored
./mirror-probe unmirror 22     # undo: stdout: unmirrored
```

### Undo the keep-alive

- Stop the engine: Ctrl-C in the engine's terminal (or from another terminal, `kill -TERM <engine-pid>`) — the virtual display dies with the process and the session-scoped mirror relationship lapses with it;
- To light the built-in panel up immediately: `caffeinate -u -t 3`.

## Usage

Running `vd-engine` or `mirror-probe` without arguments prints its usage; the notes below match it, and the program's own output is authoritative (usage and diagnostics are currently printed in Chinese).

### vd-engine

```text
用法:
  vd-engine create <W> <H> [--hidpi] [--hold]   建虚拟屏（逻辑分辨率 WxH），成功后 stdout 打印屏 id
  vd-engine remove <id>                          销毁指定虚拟屏
  vd-engine list                                 列出全部在线显示器（只读）
  vd-engine hi <id>                              打印指定屏的 HiDPI 情况（只读）
  vd-engine doctor                               环境自检+可执行建议（只读；有阻塞问题时退出码 1）

选项:
  --hidpi  逻辑 WxH、像素 2Wx2H（例: 1800 1169 --hidpi → 像素 3600x2338，HiDPI 档进模式列表）
  --hold   建完不退出，前台常驻持有该屏（Ctrl-C / SIGTERM 结束，屏随之销毁）

退出码: 0 成功 / 1 运行错 / 2 用法错
```

`remove` deliberately never fails silently: there is no cross-process destroy API, so the display you target is always held by another process — the tool explains what would actually destroy it.

In `list` output, rows with `kya=yes` are virtual displays created by this engine (vendor marker) and `main=yes` is the system's main display (usually the built-in panel).

### mirror-probe

```text
用法:
  mirror-probe mirror   <internalID> <virtualID>
  mirror-probe unmirror <virtualID>
  mirror-probe status   <displayID>
```

Direction convention: `mirror` makes the virtual display (virtualID/slave) mirror the internal display (internalID/master); `unmirror` removes virtualID's mirror relationship; `status` prints the CGDisplayMirrorsDisplay reading (read-only, no side effects).

### The lid-closed keep-alive recipe

```sh
vd-engine create 1800 1169 --hidpi --hold &
caffeinate -d &
```

Then close the lid: the screen goes dark, the machine keeps running, and visual capture is unaffected. To undo, stop the engine process (Ctrl-C or `kill`), then run `caffeinate -u -t 3` to wake the display.

## For AI agents

The precise contract for automated invocation. Two conventions hold throughout: **stdout carries only machine-readable results** (display ids / `mirrored` / `unmirrored` / readings / doctor's `check=` lines); **diagnostics and executable recovery actions go to stderr**. Branch on exit code + stdout; never parse stderr text (stderr diagnostics are currently in Chinese — written for humans).

### Exit code semantics (per source code and live measurement)

`vd-engine`:

| Exit code | Meaning | Triggered by |
|-----------|---------|--------------|
| 0 | success | `create` / `list` / `hi` / `doctor` completing normally (doctor warns still exit 0) |
| 1 | runtime error | display creation failed (private class missing / object construction failed / `applySettings:` rejected / not online within 3s); `remove` / `hi` target display not online; `list` with an empty online list; doctor found a blocking problem (fail) |
| 2 | usage error | no arguments, unknown subcommand, argument parsing failure (W/H not positive integers, invalid id, resolution above the 8192/16384 caps, doctor given extra arguments) |

`mirror-probe`:

| Exit code | Meaning | Triggered by |
|-----------|---------|--------------|
| 0 | success | `mirror` / `unmirror` took effect (read-back verified; stdout is `mirrored` / `unmirrored`); `status` prints the mirror target id |
| 1 | runtime error | either id not online; display configuration API failure; `mirror` / `unmirror` read-back not confirmed within 1s |
| 2 | usage error | no arguments, unknown subcommand, invalid id (non-numeric / 0 / internal and virtual ids identical) |

Note: `vd-engine remove` exits 1 for any online display — by design, not a malfunction (no cross-process destroy API; stderr explains the path that would actually destroy it).

### Step 0: environment self-check

```sh
vd-engine doctor    # exit 0 = no blocking problem (warns may continue) / 1 = blocking problem / 2 = usage error
```

stdout carries one `check=<key> result=<pass|warn|fail> detail=<…>` line per check; route on result:

- all pass → continue;
- `keepalive_running` warn → the engine pid / kya display id / caffeinate assertion are all in detail; if it's not a keep-alive you meant to keep, `kill -TERM <pid>`;
- `lid_sleep` warn → disable sleep with the exact command on stderr (`sudo pmset -a disablesleep 1`);
- any fail → stderr explains; abort.

### Standard keep-alive session (every expected output measured live)

```sh
# 1) Create the display and hold it. stdout prints the display id (fflush'd, readable
#    immediately even when redirected to a file); stderr prints diagnostics.
vd-engine create 1800 1169 --hidpi --hold >"$TMP/vd-id" 2>"$TMP/vd-err" &
for i in $(seq 1 30); do [ -s "$TMP/vd-id" ] && break; sleep 0.2; done
VIRTUAL_ID=$(cat "$TMP/vd-id")    # e.g. 22; the loop covers WindowServer's up-to-3s attach window
ENGINE_PID=$!
```

```sh
# 2) Inspect online displays (read-only, exit 0). kya=yes rows are ClamAwake virtual
#    displays; main=yes is the built-in display.
vd-engine list
# stdout first line: # 在线显示器 N 个（main=系统主屏）   ("N displays online, main = system main display")
# then one row per display: id=<n> main=<yes|no> builtin=<yes|no> active=<yes|no> asleep=<yes|no> mirror_of=<id|none> points=<WxH> pixels=<WxH> hidpi=<yes|no> vendor=… product=… serial=… kya=<yes|no>
```

```sh
# 3) (Optional, for visual capture) mirror the virtual display onto the built-in one:
#    <internalID> = the main=yes id from list
mirror-probe mirror "$INTERNAL_ID" "$VIRTUAL_ID"
# exit 0, stdout exactly one line: mirrored

# 4) Read-back verification (read-only, no side effects)
mirror-probe status "$VIRTUAL_ID"
# exit 0, stdout is the mirror target id (mirrored = built-in id, e.g. 1; not mirrored = 0)

# 5) Remove the mirror
mirror-probe unmirror "$VIRTUAL_ID"
# exit 0, stdout exactly one line: unmirrored
```

```sh
# 6) Teardown: end the engine — the virtual display dies with the process, and the
#    session-scoped mirror lapses with it (no need to unmirror first).
kill -TERM "$ENGINE_PID"
# verify teardown: vd-engine list no longer contains the $VIRTUAL_ID row
```

### Error-handling conventions

Every non-zero exit code comes with a reason on stderr, and most carry an executable recovery action (e.g. `remove`'s full destruction path; `status`'s "reading untrustworthy" notice for offline ids; `mirror` naming which id is offline). Run the recovery action as printed; branch programmatically only on exit codes and stdout's `check=` / `id=` / reading lines.

## Troubleshooting

### Engine fails to start (create exits 1)

stderr states the specific cause. The common three:

- 「私有类 CGVirtualDisplay 不存在」("private class CGVirtualDisplay does not exist") — this macOS lacks the private class; ClamAwake cannot work here. Run `vd-engine doctor`; a `private_class` fail confirms it. No recovery action (depends on the OS version).
- 「applySettings: 返回 NO」("applySettings: returned NO") — WindowServer rejected the mode combination. Retry with a common resolution (`1920 1080`, `1512 982`, `1800 1169`).
- 「applySettings 成功但 3s 内没在 CGGetOnlineDisplayList 里看到新屏」("settings applied but the new display didn't appear within 3s") — created but not attached. Retry once; if it still fails, run `vd-engine doctor` and check the `displays` item.

### Mirroring fails (mirror / unmirror exits 1)

- 「内屏/虚拟屏 N 不在线」("internal/virtual display N not online") — the virtual display id is probably stale: after an engine restart the display is a new one and ids change (the old id died with the old process). Re-run `vd-engine list` for current ids.
- 「镜像未生效：CGDisplayMirrorsDisplay(…)=…」("mirror did not take effect") — the configuration was submitted but read-back verification didn't pass within 1s. Retry once; check state any time with `mirror-probe status <id>` (read-only, no side effects).

### A keep-alive already exists

`vd-engine doctor`'s `keepalive_running` is warn, or `pgrep -x vd-engine` prints something:

- one vd-engine process + one `kya=yes` display + a caffeinate assertion = a running keep-alive. If you (or a previous session) meant to keep it → reuse it: take the `kya=yes` id from `vd-engine list`, don't create a duplicate.
- To start fresh: `kill -TERM <pid>` (the display dies with the process) → `create` again.
- A `kya=yes` display with no vd-engine process → created by another virtual display tool (e.g. SimpleDisplay): quit that tool, or just use its display.
- Multiple virtual displays can coexist and can mirror the same internal display simultaneously (verified live); ids are independent.

## Acknowledgments

- [pasky/hidpi-mirror](https://github.com/pasky/hidpi-mirror)
- [xtongs/mirrorscreen](https://github.com/xtongs/mirrorscreen)

Both are MIT-licensed and served as reference implementations for building virtual displays — only the calling shapes of the private APIs were studied, no code was reused.

## License

[GPL-3.0](LICENSE)

## Support

If ClamAwake has been useful to you, buy the author a coffee: [Aifadian](https://afdian.net/a/<待填>)

## Maintainer

ClamAwake is maintained by @zhangweijian97.
