// windimui — menu-bar brightness control for individual windows.
// One overlay per dimmed window, each with its own level.

import Cocoa
import SwiftUI

// ---------- CGWindowList helpers ----------

let myPID = Int(ProcessInfo.processInfo.processIdentifier)

func num(_ i: [String: Any], _ k: CFString) -> Int? { (i[k as String] as? NSNumber)?.intValue }
func wid(_ i: [String: Any]) -> CGWindowID { CGWindowID(exactly: num(i, kCGWindowNumber) ?? 0) ?? 0 }
func owner(_ i: [String: Any]) -> String { (i[kCGWindowOwnerName as String] as? String) ?? "?" }
func layerOf(_ i: [String: Any]) -> Int { num(i, kCGWindowLayer) ?? 0 }
func alphaOf(_ i: [String: Any]) -> Double { (i[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 }

func boundsOf(_ i: [String: Any]) -> CGRect? {
    guard let d = i[kCGWindowBounds as String] as? [String: Any],
          let r = CGRect(dictionaryRepresentation: d as CFDictionary) else { return nil }
    return r
}

func winList(onScreen: Bool) -> [[String: Any]] {
    let o: CGWindowListOption = onScreen ? [.optionOnScreenOnly, .excludeDesktopElements]
                                         : [.optionAll, .excludeDesktopElements]
    return (CGWindowListCopyWindowInfo(o, kCGNullWindowID) as? [[String: Any]]) ?? []
}

/// CGWindowList is top-left origin; Cocoa is bottom-left.
func cocoaRect(_ r: CGRect) -> CGRect {
    let h = NSScreen.screens.first?.frame.maxY ?? 0
    return CGRect(x: r.origin.x, y: h - r.origin.y - r.height, width: r.width, height: r.height)
}

func isPickable(_ i: [String: Any]) -> Bool {
    guard layerOf(i) == 0, num(i, kCGWindowOwnerPID) != myPID,
          let r = boundsOf(i), r.width > 120, r.height > 80 else { return false }
    return alphaOf(i) > 0.05
}

// ---------- the overlay ----------

final class DimView: NSView {
    var path: CGPath?
    var dim: CGFloat = 0
    override func draw(_ dirty: NSRect) {
        guard let p = path, dim > 0.001,
              let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.black.withAlphaComponent(dim).cgColor)
        ctx.addPath(p)
        ctx.fillPath()
    }
}

final class Overlay {
    let target: CGWindowID
    private let win: NSWindow
    private let view = DimView()
    private let union: CGRect

    init(target: CGWindowID) {
        self.target = target
        union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        win = NSWindow(contentRect: union, styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.level = NSWindow.Level(Int(CGWindowLevelForKey(.floatingWindow)))
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        win.contentView = view
        win.orderFrontRegardless()
    }

    func setDim(_ a: CGFloat) { view.dim = a; view.needsDisplay = true }

    /// Returns false when the target window no longer exists at all.
    @discardableResult
    func update(list: [[String: Any]]) -> Bool {
        guard let idx = list.firstIndex(where: { wid($0) == target }),
              let tCG = boundsOf(list[idx]) else {
            view.path = nil
            view.needsDisplay = true
            return winList(onScreen: false).contains { wid($0) == target }
        }
        let targetLayer = layerOf(list[idx])
        var region = CGPath(rect: cocoaRect(tCG).offsetBy(dx: -union.minX, dy: -union.minY), transform: nil)
        for front in list[..<idx] {
            // only real app windows can occlude; system overlays (Screenshot,
            // Spotlight, notification shade) are invisible and must be ignored
            if layerOf(front) != targetLayer { continue }
            if num(front, kCGWindowOwnerPID) == myPID { continue }
            guard alphaOf(front) > 0.05, let r = boundsOf(front) else { continue }
            let cut = cocoaRect(r).offsetBy(dx: -union.minX, dy: -union.minY)
            guard cut.intersects(region.boundingBox) else { continue }
            region = region.subtracting(CGPath(rect: cut, transform: nil))
        }
        view.path = region
        view.needsDisplay = true
        return true
    }

    func close() { win.orderOut(nil) }
}

// ---------- system brightness ----------

/// DisplayServices is private, so resolve it at runtime and degrade gracefully
/// if the symbol ever disappears.
typealias GetBrightnessFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
let getBrightnessFn: GetBrightnessFn? = {
    guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
          let sym = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
    return unsafeBitCast(sym, to: GetBrightnessFn.self)
}()

func systemBrightness() -> Double? {
    guard let fn = getBrightnessFn else { return nil }
    var v: Float = -1
    guard fn(CGMainDisplayID(), &v) == 0, v >= 0 else { return nil }
    return Double(v)
}

// ---------- model ----------

struct WinItem: Identifiable, Equatable {
    let id: CGWindowID
    let app: String
    let pid: Int
    let w: Int
    let h: Int
}

/// Slider is BRIGHTNESS: 1.0 = untouched, lower = darker. 0.15 floor keeps a
/// window readable rather than letting it go fully black.
let minBrightness = 0.15

final class Model: ObservableObject {
    @Published var items: [WinItem] = []
    @Published var levels: [CGWindowID: Double] = [:]
    @Published var followKeys = true
    private var overlays: [CGWindowID: Overlay] = [:]
    private var lastSystem: Double? = systemBrightness()

    /// Mirror hardware brightness-key presses onto every window on screen.
    /// Iterating `items` rather than `levels` is what makes this reach windows
    /// that are still at 100% — they have no overlay yet, so one gets created.
    func syncFromSystem() {
        guard let now = systemBrightness() else { return }
        defer { lastSystem = now }
        guard followKeys, let prev = lastSystem else { return }
        let delta = now - prev
        guard abs(delta) > 0.001 else { return }
        refresh()                      // the popover may be closed; items can be stale
        shiftAll(by: delta)
    }

    /// Shift every window by the same amount, preserving relative differences.
    private func shiftAll(by delta: Double) {
        let snap = winList(onScreen: true)
        for it in items {
            setBrightness(it.id, min(1.0, max(minBrightness, brightness(it.id) + delta)), list: snap)
        }
    }

    /// Master control spans all windows, so it can dim a screen that is
    /// already at hardware-minimum brightness.
    var masterLevel: Double {
        guard !items.isEmpty else { return 1.0 }
        return items.map { brightness($0.id) }.reduce(0, +) / Double(items.count)
    }
    func setMaster(_ v: Double) {
        let delta = v - masterLevel
        guard abs(delta) > 0.0001 else { return }
        shiftAll(by: delta)
    }

    func refresh() {
        let found = winList(onScreen: true).filter(isPickable).map { i -> WinItem in
            let r = boundsOf(i)!
            return WinItem(id: wid(i), app: owner(i), pid: num(i, kCGWindowOwnerPID) ?? 0,
                           w: Int(r.width), h: Int(r.height))
        }
        if found != items { items = found }
    }

    func brightness(_ id: CGWindowID) -> Double { levels[id] ?? 1.0 }

    func setBrightness(_ id: CGWindowID, _ v: Double, list: [[String: Any]]? = nil) {
        levels[id] = v
        if v >= 0.995 {
            overlays[id]?.close()
            overlays.removeValue(forKey: id)
            levels.removeValue(forKey: id)
            return
        }
        let o = overlays[id] ?? { let n = Overlay(target: id); overlays[id] = n; return n }()
        o.setDim(CGFloat(1.0 - v))
        o.update(list: list ?? winList(onScreen: true))
    }

    func resetAll() {
        for (_, o) in overlays { o.close() }
        overlays.removeAll()
        levels.removeAll()
    }

    var dimmedCount: Int { overlays.count }

    func tick() {
        guard !overlays.isEmpty else { return }
        let list = winList(onScreen: true)
        for (id, o) in overlays where !o.update(list: list) {
            o.close()
            overlays.removeValue(forKey: id)
            levels.removeValue(forKey: id)
        }
    }
}

// ---------- panel ----------

struct Row: View {
    let item: WinItem
    @ObservedObject var model: Model

    var body: some View {
        let b = Binding(get: { model.brightness(item.id) },
                        set: { model.setBrightness(item.id, $0) })
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let icon = NSRunningApplication(processIdentifier: pid_t(item.pid))?.icon {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                }
                Text(item.app).font(.system(size: 12, weight: .medium))
                Text("\(item.w)×\(item.h)").font(.system(size: 10)).foregroundColor(.secondary)
                Spacer()
                Text("\(Int(b.wrappedValue * 100))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(b.wrappedValue < 0.995 ? .accentColor : .secondary)
            }
            HStack(spacing: 6) {
                Image(systemName: "sun.min").font(.system(size: 9)).foregroundColor(.secondary)
                Slider(value: b, in: minBrightness...1.0)
                Image(systemName: "sun.max").font(.system(size: 9)).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct Panel: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Window Brightness").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Reset") { model.resetAll() }
                    .buttonStyle(.borderless).font(.system(size: 11))
                    .disabled(model.dimmedCount == 0)
            }
            if !model.items.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "circle.lefthalf.filled").font(.system(size: 11))
                        Text("All windows (\(model.items.count))")
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        Text("\(Int(model.masterLevel * 100))%")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.accentColor)
                    }
                    Slider(value: Binding(get: { model.masterLevel },
                                          set: { model.setMaster($0) }),
                           in: minBrightness...1.0)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
                Toggle(isOn: $model.followKeys) {
                    Text("Follow the brightness keys").font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
            }
            Divider()
            if model.items.isEmpty {
                Text("No windows found").font(.system(size: 11)).foregroundColor(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.items) { Row(item: $0, model: model) }
                    }
                }
                .frame(maxHeight: 320)
            }
            Divider()
            HStack {
                Text("Drag left to dim · brightness keys move all").font(.system(size: 10)).foregroundColor(.secondary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless).font(.system(size: 11))
            }
        }
        .padding(12)
        .frame(width: 310)
    }
}

// ---------- app ----------

let model = Model()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
statusItem.button?.image = NSImage(systemSymbolName: "circle.lefthalf.filled",
                                   accessibilityDescription: "Window Brightness")
statusItem.button?.image?.isTemplate = true

let popover = NSPopover()
popover.behavior = .transient
popover.contentViewController = NSHostingController(rootView: Panel(model: model))

final class Clicker {
    @objc func toggle(_ sender: Any?) {
        guard let b = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.refresh()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        }
    }
}
let clicker = Clicker()
statusItem.button?.target = clicker
statusItem.button?.action = #selector(Clicker.toggle(_:))

Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { _ in model.tick() }
Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in model.syncFromSystem() }
Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
    if popover.isShown { model.refresh() }
}
model.refresh()
app.run()
