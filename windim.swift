// windim — dim a single on-screen window with a click-through overlay.
// No extensions, no Accessibility/Screen-Recording permissions: window bounds
// and owner names come from CGWindowList, which is readable unprivileged.

import Cocoa

// ---------- geometry helpers ----------

/// CGWindowList uses global coords with origin at the TOP-left of the primary
/// display; Cocoa uses BOTTOM-left. Flip across the primary display's height.
func cocoaRect(fromCG r: CGRect) -> CGRect {
    let primaryH = NSScreen.screens.first?.frame.maxY ?? 0
    return CGRect(x: r.origin.x, y: primaryH - r.origin.y - r.height,
                  width: r.width, height: r.height)
}

func bounds(of info: [String: Any]) -> CGRect? {
    guard let d = info[kCGWindowBounds as String] as? [String: Any],
          let r = CGRect(dictionaryRepresentation: d as CFDictionary) else { return nil }
    return r
}

func windowList(onScreenOnly: Bool) -> [[String: Any]] {
    let opts: CGWindowListOption = onScreenOnly ? [.optionOnScreenOnly, .excludeDesktopElements]
                                                : [.optionAll, .excludeDesktopElements]
    return (CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]) ?? []
}

func num(_ info: [String: Any], _ key: CFString) -> Int? {
    (info[key as String] as? NSNumber)?.intValue
}
func wid(_ info: [String: Any]) -> CGWindowID {
    CGWindowID(exactly: num(info, kCGWindowNumber) ?? 0) ?? 0
}
func owner(_ info: [String: Any]) -> String {
    (info[kCGWindowOwnerName as String] as? String) ?? "?"
}
func layer(_ info: [String: Any]) -> Int {
    num(info, kCGWindowLayer) ?? 0
}
func alphaOf(_ info: [String: Any]) -> Double {
    (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
}

/// Ordinary app windows big enough to be worth dimming.
func isPickable(_ info: [String: Any]) -> Bool {
    guard layer(info) == 0, let r = bounds(of: info), r.width > 120, r.height > 80 else { return false }
    return alphaOf(info) > 0.05
}

// ---------- argument parsing ----------

var dimAlpha: Double = 0.55
var targetID: CGWindowID? = nil
var appName: String? = nil
var pickDelay: Double = 0
var doPick = false
var doList = false

var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    switch args[i] {
    case "--list": doList = true
    case "--pick": doPick = true
    case "--alpha": i += 1; dimAlpha = Double(args[safe: i] ?? "") ?? dimAlpha
    case "--id":    i += 1; targetID = CGWindowID(args[safe: i] ?? "") ?? nil
    case "--app":   i += 1; appName = args[safe: i]
    case "--delay": i += 1; pickDelay = Double(args[safe: i] ?? "") ?? 0
    default: break
    }
    i += 1
}
extension Array {
    subscript(safe idx: Int) -> Element? { indices.contains(idx) ? self[idx] : nil }
}

if doList {
    for w in windowList(onScreenOnly: true) where isPickable(w) {
        let r = bounds(of: w)!
        print(String(format: "%-8d %-24s %4.0fx%-5.0f @ %4.0f,%-5.0f",
                     Int(wid(w)), (owner(w) as NSString).utf8String!,
                     r.width, r.height, r.origin.x, r.origin.y))
    }
    exit(0)
}

// ---------- choose the target window ----------

func pickUnderMouse() -> CGWindowID? {
    let m = NSEvent.mouseLocation                       // Cocoa coords
    let primaryH = NSScreen.screens.first?.frame.maxY ?? 0
    let p = CGPoint(x: m.x, y: primaryH - m.y)          // -> CG coords
    for w in windowList(onScreenOnly: true) where isPickable(w) {
        if bounds(of: w)!.contains(p) { return wid(w) }  // list is front-to-back
    }
    return nil
}

if doPick {
    if pickDelay > 0 {
        FileHandle.standardError.write("Hover the window to dim… \(Int(pickDelay))s\n".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: pickDelay)
    }
    targetID = pickUnderMouse()
} else if let name = appName {
    let want = name.lowercased()
    targetID = windowList(onScreenOnly: true)
        .first { isPickable($0) && owner($0).lowercased().contains(want) }
        .map { wid($0) }
}

guard let target = targetID else {
    FileHandle.standardError.write("windim: no matching window\n".data(using: .utf8)!)
    exit(1)
}

// ---------- overlay ----------

final class DimView: NSView {
    var path: CGPath?
    var dim: CGFloat = 0.55
    override func draw(_ dirty: NSRect) {
        guard let p = path, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.black.withAlphaComponent(dim).cgColor)
        ctx.addPath(p)
        ctx.fillPath()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
let view = DimView()
view.dim = CGFloat(dimAlpha)

let win = NSWindow(contentRect: union, styleMask: .borderless, backing: .buffered, defer: false)
win.isOpaque = false
win.backgroundColor = .clear
win.hasShadow = false
win.ignoresMouseEvents = true                       // clicks pass straight through
win.level = NSWindow.Level(Int(CGWindowLevelForKey(.floatingWindow)))
win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
win.contentView = view
win.orderFrontRegardless()

let myPID = Int(ProcessInfo.processInfo.processIdentifier)
let myWindowNumber = win.windowNumber
var missingTicks = 0
let debug = CommandLine.arguments.contains("--debug")
var tickCount = 0
func log(_ m: String) {
    FileHandle.standardError.write((m + "\n").data(using: .utf8)!)
}

/// Target rect minus every window stacked in front of it, so the dim only ever
/// paints the part of that window you can actually see.
func visiblePath() -> CGPath? {
    let list = windowList(onScreenOnly: true)
    guard let idx = list.firstIndex(where: { wid($0) == target }),
          let tCG = bounds(of: list[idx]) else { return nil }

    var region = CGPath(rect: cocoaRect(fromCG: tCG).offsetBy(dx: -union.minX, dy: -union.minY),
                        transform: nil)
    let targetLayer = layer(list[idx])
    var cutCount = 0
    for front in list[..<idx] {
        if layer(front) != targetLayer { continue }
        // skip our own overlay: it is full-screen and in front of everything,
        // so failing to skip it wipes the whole region
        if num(front, kCGWindowOwnerPID) == myPID { continue }
        if Int(wid(front)) == myWindowNumber { continue }
        guard alphaOf(front) > 0.05, let r = bounds(of: front) else { continue }
        let cut = cocoaRect(fromCG: r).offsetBy(dx: -union.minX, dy: -union.minY)
        guard cut.intersects(region.boundingBox) else { continue }
        region = region.subtracting(CGPath(rect: cut, transform: nil))
        cutCount += 1
        if debug { log("   cut by \(owner(front)) #\(wid(front)) layer=\(layer(front))") }
    }
    if debug { log("   occluders=\(cutCount) pathBBox=\(region.boundingBox) empty=\(region.isEmpty)") }
    return region
}

func tick() {
    let onScreen = windowList(onScreenOnly: true).contains { wid($0) == target }
    if !onScreen {
        // minimised, hidden, or on another Space: stop painting but keep waiting
        view.path = nil
        view.needsDisplay = true
        missingTicks = windowList(onScreenOnly: false).contains { wid($0) == target } ? 0 : missingTicks + 1
        if missingTicks > 45 { exit(0) }   // window closed for ~3s
        return
    }
    missingTicks = 0
    tickCount += 1
    if debug && tickCount % 15 == 1 {
        log("tick \(tickCount) dim=\(view.dim) myPID=\(myPID) myWin=\(myWindowNumber)")
        view.path = visiblePath()
    } else {
        view.path = visiblePath()
    }
    view.needsDisplay = true
}

// SIGUSR1 = darker, SIGUSR2 = lighter — lets the wrapper adjust a live overlay.
signal(SIGUSR1, SIG_IGN)
signal(SIGUSR2, SIG_IGN)
let darker = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
darker.setEventHandler { view.dim = min(0.92, view.dim + 0.08); view.needsDisplay = true }
darker.resume()
let lighter = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
lighter.setEventHandler {
    view.dim = max(0.0, view.dim - 0.08)
    if view.dim < 0.04 { exit(0) }
    view.needsDisplay = true
}
lighter.resume()

Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { _ in tick() }
tick()
app.run()
