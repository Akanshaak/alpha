# Building native Mac tools — what windim actually is

## What we built

Three pieces in `~/tools/windim/`:

| file | what it is |
|---|---|
| `windim` | CLI overlay: dim one window, control it with signals |
| `windimui` | menu-bar app: status item + SwiftUI panel, N overlays at once |
| `~/bin/dim` | zsh wrapper so you type words, not flags |

Both binaries are single-file Swift, compiled with `swiftc -O -o windim windim.swift`.
No Xcode project, no `.xcodeproj`, no package manifest. A macOS GUI app is just an
executable that links AppKit and calls `NSApplication.shared.run()`.

## The core idea: there is no "window brightness"

macOS has one brightness value per physical display, driven by the backlight.
Your MacBook Air has exactly one panel, so there is nothing to dim per-window.

So we don't dim anything. We **composite a black rectangle on top**, shaped to
match the target window. Brightness 40% = a black layer at alpha 0.6. That's the
whole trick, and it's how every app of this kind (HazeOver, Shades) works.

Consequence worth internalising: the backlight and our overlay are physically
independent. Raising the hardware brightness raises the panel under *everything*,
including the pixels we're darkening. That's why the keys felt disconnected —
until we explicitly linked them by polling the system brightness value.

## The four system APIs this uses

### 1. CGWindowList — reading the window tree (no permission)
```swift
CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
```
Returns every window on screen, **front to back**, as dictionaries: window id,
owner pid, owner app name, bounds, layer, alpha.

Unprivileged. The one thing it withholds without Screen Recording permission is
`kCGWindowName` (the window *title*). Bounds and app names are free — which is
exactly why this tool needs no permission dialog.

### 2. NSWindow — drawing above other apps
```swift
win.level = NSWindow.Level(Int(CGWindowLevelForKey(.floatingWindow)))  // 3
win.ignoresMouseEvents = true      // clicks pass straight through
win.isOpaque = false               // alpha compositing
win.collectionBehavior = [.canJoinAllSpaces, .stationary, ...]
```
`level` is the z-order band. Normal app windows are **0**. Floating panels **3**.
Dock ~20, menu bar ~25. Within a band it's front-to-back; across bands the higher
band always wins. You cannot put your window *between* two other apps' normal
windows — hence the overlay floats above and we subtract what covers the target.

### 3. CGPath boolean geometry — the occlusion mask
```swift
region = CGPath(rect: targetRect)
for front in windowsInFrontOfTarget { region = region.subtracting(CGPath(rect: front)) }
```
Target rect minus everything stacked on top, so the dim only paints visible pixels.
`CGPath.subtracting` is macOS 13+.

### 4. DisplayServices — reading the hardware brightness (private)
```swift
dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
dlsym(handle, "DisplayServicesGetBrightness")
```
Not a public API. We resolve it at runtime with `dlopen`/`dlsym` and fall back to
"feature off" if the symbol ever vanishes. That's the discipline for private
frameworks: never link them, always probe, always degrade.

Polling it every 200ms and applying the *delta* to each overlay is what makes the
brightness keys act as a master control — without intercepting a single keystroke.

## Coordinate systems — the classic Mac bug

Two conventions, and they disagree:

- **CoreGraphics / CGWindowList**: origin **top-left**, y grows down.
- **Cocoa / NSWindow / NSView**: origin **bottom-left**, y grows up.

Every CGWindowList rect must be flipped before you draw with it:
```swift
cocoaY = primaryScreen.frame.maxY - cgY - height
```
Get this wrong and your overlay lands mirrored vertically. If something draws in
the wrong place on macOS, this is the first thing to check.

## Permissions (TCC) — what costs a dialog

| capability | permission needed |
|---|---|
| window bounds, app names, z-order | **none** |
| drawing overlay windows anywhere | **none** |
| reading system brightness (private API) | **none** |
| window **titles** (`kCGWindowName`) | Screen Recording |
| `screencapture`, any pixel reading | Screen Recording |
| intercepting keystrokes (`CGEventTap`) | Accessibility |
| moving/resizing other apps' windows (AX API) | Accessibility |

This tool deliberately stays entirely in the free column. That design constraint
is why it worked the moment it compiled, with no System Settings trip.

A caveat if you ever do need permission: a bare binary run from Terminal is
attributed to **Terminal.app**, not itself. To get its own TCC identity you must
wrap it in a `.app` bundle and ad-hoc sign it (`codesign -s - --force`).

## Process shapes on macOS

1. **Bare executable** (what we have) — run from shell, dies with no supervision.
2. **`.app` bundle** — a directory: `Foo.app/Contents/{MacOS/foo, Info.plist}`.
   Gets its own TCC identity, Dock icon, Launchpad entry, double-clickable.
   `Info.plist` key `LSUIElement = true` means "menu-bar only, no Dock icon".
3. **LaunchAgent** — a plist in `~/Library/LaunchAgents/`, loaded by `launchd`
   at login, with `KeepAlive` for restart-on-crash. This is the macOS equivalent
   of a user-scope systemd unit, and maps directly onto what you already know.

`setActivationPolicy(.accessory)` is the runtime equivalent of `LSUIElement` —
it's why the panel has no Dock icon and never steals focus.

## The UI layer

```
NSStatusItem   -> the menu-bar icon (NSStatusBar.system.statusItem)
NSPopover      -> the panel that drops down, .transient = closes on outside click
NSHostingController -> bridge that puts a SwiftUI view inside AppKit
```
SwiftUI handles the sliders and list; AppKit handles the window plumbing. Mixing
them is normal and supported — SwiftUI alone can't do click-through overlay windows.

The data flow is `ObservableObject` + `@Published`: mutate the model, SwiftUI
re-renders. A 15Hz timer re-computes overlay geometry; a 5Hz timer polls brightness;
a 1Hz timer refreshes the window list while the panel is open.

## Signals as a control channel

`windim` takes `SIGUSR1`/`SIGUSR2` to step its level:
```swift
signal(SIGUSR1, SIG_IGN)                       // disable default terminate
let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
src.setEventHandler { ... }; src.resume()
```
Zero-dependency IPC for a single-knob daemon. For anything richer you'd use a
unix socket, XPC, or distributed notifications.

## Two debugging lessons from building this

**"The process is alive" proves nothing.** The first version ran for twenty
minutes painting absolutely nothing, and every health check passed. Verify the
*output*, not the liveness.

**The bug was an invisible window.** macOS Screenshot.app keeps a full-screen,
fully transparent window in front of everything. The occlusion loop subtracted it
and wiped the region to empty. Nothing in the code looked wrong — the fix only
became obvious after printing the occluder list. Instrument, don't theorise:
one `log()` of the cut list found in ten seconds what guessing had missed twice.

The fix: only windows at **the same layer as the target** can occlude it. System
overlays live at higher layers and are invisible by design.

## What else is buildable with this same toolkit

- **Window manager** — needs Accessibility (AXUIElement) to move/resize.
- **Hotkey daemon** — `RegisterEventHotKey` (Carbon) needs *no* permission for
  normal key combos; only `CGEventTap` (raw interception) needs Accessibility.
- **Clipboard manager** — poll `NSPasteboard.general.changeCount`, no permission.
- **Menu-bar monitors** — anything you can read, you can put in the menu bar.
- **File watchers** — FSEvents, or `DispatchSource.makeFileSystemObjectSource`.
- **Screen-time / focus tools** — `NSWorkspace.shared.frontmostApplication` plus
  `NSWorkspace.didActivateApplicationNotification`, no permission.

## Where to look things up

- `man swiftc`, and `swiftc -` for a REPL-ish scratchpad
- Apple docs for AppKit / CoreGraphics (`developer.apple.com/documentation`)
- Private framework symbols: `nm -gU /System/Library/PrivateFrameworks/X.framework/X`
- Live window inspection: the `--list` flag in `windim` is 10 lines and worth
  copying into any Mac tool you write

## Build / run

```sh
cd ~/tools/windim
swiftc -O -o windim   windim.swift
swiftc -O -o windimui windimui.swift

~/bin/dim ui        # start the menu-bar panel
~/bin/dim off       # kill everything
```
