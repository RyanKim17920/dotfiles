// wez-drag: Finder drag and drop for a terminal that can't do it itself.
//
//   wez-drag out [--timeout S] <files...>
//       A small floating window near the mouse shows the files; drag them
//       out to Finder, the Desktop, Mail... It closes after a drop, on Esc
//       or after S seconds idle (default 60). Exit 0 after a drop, 1 if
//       cancelled.
//   wez-drag in --dest <label> [--timeout S]
//       A drop zone labelled with the destination. Files and folders dropped
//       on it are printed to stdout as absolute paths, each followed by a
//       NUL, then it exits 0. It copies nothing: the caller uploads. Exit 1
//       if cancelled (Esc, idle timeout).
//
// No Dock icon (accessory app). Build: macos/wez-drag/build.sh
import AppKit

let usage = """
    usage: wez-drag out [--timeout S] <files...>
           wez-drag in --dest <label> [--timeout S]

    """

func fail(_ msg: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data(("wez-drag: " + msg + "\n").utf8))
    exit(code)
}

// Arguments ---------------------------------------------------------------

enum Mode { case dragOut([URL]), dropIn(String) }

var args = Array(CommandLine.arguments.dropFirst())
guard let verb = args.first else { fail(usage) }
args.removeFirst()
var timeout: TimeInterval = 60
var dest: String?
var paths: [String] = []
while !args.isEmpty {
    let a = args.removeFirst()
    if a == "--timeout" || a == "--dest" {
        guard let v = args.first else { fail("\(a) needs a value") }
        args.removeFirst()
        if a == "--dest" {
            dest = v
        } else if let t = TimeInterval(v), t > 0 {
            timeout = t
        } else {
            fail("bad --timeout: \(v)")
        }
    } else if a == "--" {
        paths += args
        args = []
    } else {
        paths.append(a)
    }
}

let mode: Mode
switch verb {
case "out":
    var urls: [URL] = []
    for p in paths {
        if FileManager.default.fileExists(atPath: p) {
            urls.append(URL(fileURLWithPath: p).standardizedFileURL)
        } else {
            FileHandle.standardError.write(Data("wez-drag: no such file: \(p)\n".utf8))
        }
    }
    if urls.isEmpty { fail("nothing to drag", code: 1) }
    mode = .dragOut(urls)
case "in":
    guard let d = dest, paths.isEmpty else { fail(usage) }
    mode = .dropIn(d)
default:
    fail(usage)
}

// Views -------------------------------------------------------------------

let pad: CGFloat = 14
let iconSize: CGFloat = 48

func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = .systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.alignment = .center
    l.lineBreakMode = .byTruncatingMiddle
    return l
}

/// Everything that should keep the window open counts as activity.
final class Idle {
    private(set) var last = Date()
    func touch() { last = Date() }
}
let idle = Idle()

/// Shows the files and starts a drag session of all of them on mouse drag.
final class DragSourceView: NSView, NSDraggingSource {
    let urls: [URL]
    private var downEvent: NSEvent?

    init(frame: NSRect, urls: [URL]) {
        self.urls = urls
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    // Up to 4 icons fanned out, then the name or the count below
    override func draw(_ dirtyRect: NSRect) {
        let shown = urls.prefix(4)
        let step: CGFloat = 10
        let width = iconSize + step * CGFloat(shown.count - 1)
        var x = (bounds.width - width) / 2
        let y = bounds.height - pad - iconSize
        for u in shown.reversed() {
            NSWorkspace.shared.icon(forFile: u.path)
                .draw(in: NSRect(x: x, y: y, width: iconSize, height: iconSize))
            x += step
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { downEvent = event; idle.touch() }
    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent else { return }
        downEvent = nil
        idle.touch()
        let origin = convert(down.locationInWindow, from: nil)
        let items = urls.enumerated().map { i, u -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: u as NSURL)
            let off = CGFloat(min(i, 4)) * 6
            item.setDraggingFrame(NSRect(x: origin.x - iconSize / 2 + off, y: origin.y - iconSize / 2 - off,
                                         width: iconSize, height: iconSize),
                                  contents: NSWorkspace.shared.icon(forFile: u.path))
            return item
        }
        let session = beginDraggingSession(with: items, event: down, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }
    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) { idle.touch() }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        idle.touch()
        if operation != [] { exit(0) }
    }
}

/// Accepts files and folders, prints their paths NUL-separated and quits.
final class DropView: NSView {
    var highlighted = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        // Below the title bar's close button
        let r = NSRect(x: 8, y: 8, width: bounds.width - 16, height: bounds.height - 38)
        let p = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
        p.lineWidth = 2
        p.setLineDash([6, 4], count: 2, phase: 0)
        (highlighted ? NSColor.controlAccentColor : NSColor.secondaryLabelColor).setStroke()
        if highlighted {
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
            p.fill()
        }
        p.stroke()
    }

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        let objs = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true])
        return (objs as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        idle.touch()
        guard !fileURLs(sender).isEmpty else { return [] }
        highlighted = true
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        idle.touch()
        return highlighted ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        var out = Data()
        for u in urls {
            out.append(Data(u.standardizedFileURL.path.utf8))
            out.append(0)
        }
        FileHandle.standardOutput.write(out)
        // Quit after the drop finishes, so Finder's drag ends cleanly
        DispatchQueue.main.async { exit(0) }
        return true
    }
}

// Window ------------------------------------------------------------------

final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { exit(1) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: Panel!

    func applicationDidFinishLaunching(_ note: Notification) {
        let content: NSView
        let size: NSSize
        switch mode {
        case .dragOut(let urls):
            size = NSSize(width: 260, height: 160)
            let v = DragSourceView(frame: NSRect(origin: .zero, size: size), urls: urls)
            let all = urls.map(\.lastPathComponent)
            let title = label(urls.count == 1 ? all[0] : "\(urls.count) items", size: 13, weight: .semibold,
                              color: .labelColor)
            let names = label(urls.count == 1 ? "" : all.joined(separator: ", "), size: 11, weight: .regular,
                              color: .secondaryLabelColor)
            let hint = label("Drag to Finder · Esc closes", size: 11, weight: .regular, color: .tertiaryLabelColor)
            title.frame = NSRect(x: pad, y: 52, width: size.width - 2 * pad, height: 18)
            names.frame = NSRect(x: pad, y: 34, width: size.width - 2 * pad, height: 16)
            hint.frame = NSRect(x: pad, y: 12, width: size.width - 2 * pad, height: 16)
            title.toolTip = all.joined(separator: "\n")
            for l in [title, names, hint] { v.addSubview(l) }
            content = v
        case .dropIn(let dest):
            size = NSSize(width: 260, height: 140)
            let v = DropView(frame: NSRect(origin: .zero, size: size))
            let head = label("Drop files to upload to", size: 12, weight: .regular, color: .secondaryLabelColor)
            let where_ = label(dest, size: 13, weight: .semibold, color: .labelColor)
            let hint = label("Esc closes", size: 11, weight: .regular, color: .tertiaryLabelColor)
            head.frame = NSRect(x: pad, y: 76, width: size.width - 2 * pad, height: 16)
            where_.frame = NSRect(x: pad, y: 54, width: size.width - 2 * pad, height: 18)
            where_.toolTip = dest
            hint.frame = NSRect(x: pad, y: 24, width: size.width - 2 * pad, height: 14)
            // Labels must not swallow the drop
            for l in [head, where_, hint] { l.unregisterDraggedTypes() }
            v.addSubview(head)
            v.addSubview(where_)
            v.addSubview(hint)
            content = v
        }

        panel = Panel(contentRect: NSRect(origin: nearMouse(size), size: size),
                      styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView],
                      backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.level = .floating
        panel.hidesOnDeactivate = false // stay up while Finder is in front
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = content
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        // Key without activating: the terminal stays the active app
        panel.makeKeyAndOrderFront(nil)

        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            if Date().timeIntervalSince(idle.last) > timeout { exit(1) }
        }
    }

    // Closing the window (its close button) cancels
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ note: Notification) { exit(1) }

    /// Bottom-left corner that puts the window just below-right of the mouse,
    /// kept on the mouse's screen
    func nearMouse(_ size: NSSize) -> NSPoint {
        let m = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(m) } ?? NSScreen.main
        var p = NSPoint(x: m.x + 12, y: m.y - 12 - size.height)
        if let f = screen?.visibleFrame {
            p.x = max(f.minX, min(p.x, f.maxX - size.width))
            p.y = max(f.minY, min(p.y, f.maxY - size.height))
        }
        return p
    }
}

// Esc anywhere in the app cancels, even if the panel isn't key
NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
    if e.keyCode == 53 { exit(1) }
    idle.touch()
    return e
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
