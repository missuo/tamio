//
//  Bench.swift
//  Tamio (macOS)
//
//  Measurements for the Files page, in debug builds only. Launch with
//  TAMIO_BENCH_FILES=<count> to fill a page with that many entries and time
//  showing them, selecting, filtering, a transfer's progress ticks and scrolling.
//  Results go to the log, one "BENCH" line each.
//

#if DEBUG
    import Combine
    import MachineStatusView
    import NSRemoteShell
    import TamioDesign
    import TamioModule
    import TamioTerminal
import SwiftUI
    import AppKit

    extension Notification.Name {
        /// userInfo: "select" (Int, an index into the sorted list) or "filter" (String).
        static let benchFiles = Notification.Name("sb.moe.tamio.bench.files")
    }

    /// What the run loop observer in `settle` records: written on the main
    /// run loop only, read after the observer is removed. The box hands the
    /// capture to the C callback as one Sendable object.
    private final class RunLoopLoad: @unchecked Sendable {
        var busy = 0.0
        var stretch = 0.0
        var woke = CACurrentMediaTime()
        let start = CACurrentMediaTime()
        /// Each stretch of work over 12 ms: when it began, after the action, and how long it ran.
        var long: [(at: Double, ms: Double)] = []
    }

    @MainActor
    enum Bench {
        static func runIfRequested() {
            if ProcessInfo.processInfo.environment["TAMIO_BENCH_ICONS"] != nil { NSLog("BENCH icons %@", RXIcon.diagnosis) }
            if ProcessInfo.processInfo.environment["TAMIO_PREVIEW_FILES"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Task { await previewFiles() } }
            }
            if let pages = ProcessInfo.processInfo.environment["TAMIO_BENCH_SIDEBAR"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Task { await sidebar(pages) } }
            }
            if ProcessInfo.processInfo.environment["TAMIO_BENCH_SETTINGS"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Task { await settings() } }
            }
            // "servers", "home"…: opens that page, for a screenshot.
            if let page = ProcessInfo.processInfo.environment["TAMIO_PREVIEW_ROUTE"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    switch page {
                    case "servers": AppRouter.shared.route = .servers
                    case "identities": AppRouter.shared.route = .identities
                    case "snippets": AppRouter.shared.route = .snippets
                    case "portForward": AppRouter.shared.route = .portForward
                    case "newServer": AppRouter.shared.presentNewServer = true
                    case "terminal":
                        // A terminal on the first server, for its toolbar.
                        if let machine = TamioStore.shared.machineGroup.machines.first {
                            TerminalManager.shared.createSession(withMachineID: machine.id)
                            if let context = TerminalManager.shared.sessionContexts.last {
                                AppRouter.shared.route = .terminal(context.id)
                            }
                        }
                    default: AppRouter.shared.route = .home
                    }
                    if ProcessInfo.processInfo.environment["TAMIO_BENCH_LIVE"] != nil { LiveStatusCenter.shared.installPreviews() }
                }
            }
            // TAMIO_PREVIEW_SNAPSHOT=<path.png>: the main window's contents,
            // drawn by AppKit, four seconds in (TAMIO_PREVIEW_SNAPSHOT_AT).
            if let path = ProcessInfo.processInfo.environment["TAMIO_PREVIEW_SNAPSHOT"] {
                let delay = Double(ProcessInfo.processInfo.environment["TAMIO_PREVIEW_SNAPSHOT_AT"] ?? "") ?? 4
                if let width = Double(ProcessInfo.processInfo.environment["TAMIO_BENCH_WIDTH"] ?? "") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        guard let window = Mac.mainWindow else { return }
                        var frame = window.frame
                        frame.size.width = width
                        frame.size.height = Double(ProcessInfo.processInfo.environment["TAMIO_BENCH_HEIGHT"] ?? "") ?? frame.height
                        window.setFrame(frame, display: true)
                    }
                }
                // TAMIO_PREVIEW_SNAPSHOT_SLIDE=1: toggles the sidebar, twice,
                // and takes a picture every 40 ms of each slide.
                let slide = ProcessInfo.processInfo.environment["TAMIO_PREVIEW_SNAPSHOT_SLIDE"] != nil
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    // TAMIO_PREVIEW_SCROLL=<points>: the page scrolled that far first.
                    if let y = Double(ProcessInfo.processInfo.environment["TAMIO_PREVIEW_SCROLL"] ?? ""),
                       let content = Mac.mainWindow?.contentView, let scroller = largestScrollView(in: content)
                    {
                        scroller.contentView.scroll(to: NSPoint(x: 0, y: y))
                        scroller.reflectScrolledClipView(scroller.contentView)
                    }
                    guard slide else {
                        snapshot(path)
                        return NSLog("BENCH done")
                    }
                    // The toggle goes to the key window's responder chain.
                    MainWindow.show()
                    for round in 0 ..< 2 {
                        let start = 0.5 + Double(round) * 1.2
                        DispatchQueue.main.asyncAfter(deadline: .now() + start) { toggleSidebar() }
                        for step in 0 ..< 9 {
                            DispatchQueue.main.asyncAfter(deadline: .now() + start + Double(step) * 0.04) {
                                snapshot(path.replacingOccurrences(of: ".png", with: "-\(round)-\(step).png"))
                            }
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { NSLog("BENCH done") }
                }
            }
            // TAMIO_PREVIEW_ABOUT=<path.png>: the About panel, captured.
            if let path = ProcessInfo.processInfo.environment["TAMIO_PREVIEW_ABOUT"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Mac.showAbout() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                    typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
                    if let panel = NSApp.windows.first(where: { $0.isVisible && $0 is NSPanel }),
                       let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
                       let image = unsafeBitCast(symbol, to: Capture.self)(.null, 1 << 3, UInt32(panel.windowNumber), 1 | 8)?.takeRetainedValue()
                    {
                        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    }
                    NSLog("BENCH done")
                }
            }
            if let pages = ProcessInfo.processInfo.environment["TAMIO_BENCH_PAGESCROLL"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Task { await pageScroll(pages) } }
            }
            guard let value = ProcessInfo.processInfo.environment["TAMIO_BENCH_FILES"], let count = Int(value) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Task { await files(count) } }
        }

        /// How long the main thread worked in the 0.4 s after the action: the
        /// state change, SwiftUI's update, layout and the commit to the render
        /// server, wherever in that window they ran.
        /// The longest single stretch of work in the last `settle`: the hitch.
        static var longest = 0.0
        /// The long stretches of work in the last `settle`, for a log line.
        static var stretches = ""

        static func settle(for seconds: Double = 0.4, _ action: () -> Void) async -> Double {
            let load = RunLoopLoad()
            let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
            let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, CFIndex.max) { _, activity in
                let now = CACurrentMediaTime()
                if activity == .afterWaiting { load.woke = now } else {
                    let ran = now - load.woke
                    load.busy += ran
                    load.stretch = max(load.stretch, ran)
                    if ran > 0.012 { load.long.append((load.woke - load.start, ran)) }
                    load.woke = now
                }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            action()
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            longest = load.stretch * 1000
            stretches = load.long.map { String(format: "+%.0f:%.0fms", $0.at * 1000, $0.ms * 1000) }.joined(separator: " ")
            return load.busy * 1000
        }

        /// Collapses and expands the sidebar the way its toolbar button does,
        /// on each page named in TAMIO_BENCH_SIDEBAR ("home,servers,settings,
        /// terminal"). TAMIO_BENCH_SERVERS=<n> first adds n servers no one
        /// answers at (for a copy of the app with its own store only), and
        /// TAMIO_BENCH_TERMINALS=<n> opens n terminals to them.
        static func sidebar(_ pages: String) async {
            let environment = ProcessInfo.processInfo.environment
            let servers = Int(environment["TAMIO_BENCH_SERVERS"] ?? "") ?? 0
            if servers > 0, TamioStore.shared.machineGroup.machines.isEmpty {
                LiveStatusCenter.shared.isEnabled = false
                for index in 0 ..< servers {
                    TamioStore.shared.machineGroup.insert(RDMachine(
                        remoteAddress: "203.0.113.\(index + 1)", remotePort: "22", name: "bench-\(index + 1)", group: index % 3 == 0 ? "Web" : "DB"
                    ))
                }
            }
            // TAMIO_BENCH_KEEP=<n> takes the made-up servers away down to n.
            if let keep = Int(environment["TAMIO_BENCH_KEEP"] ?? "") {
                for machine in TamioStore.shared.machineGroup.machines.filter({ $0.name.hasPrefix("bench-") }).reversed()
                    where TamioStore.shared.machineGroup.machines.count > keep
                {
                    TamioStore.shared.machineGroup.delete(machine.id)
                }
            }
            // TAMIO_BENCH_LIVE=1 gives every card made-up live readings.
            if environment["TAMIO_BENCH_LIVE"] != nil { LiveStatusCenter.shared.installPreviews() }
            for machine in TamioStore.shared.machineGroup.machines.prefix(Int(environment["TAMIO_BENCH_TERMINALS"] ?? "") ?? 0) {
                TerminalManager.shared.createSession(withMachineID: machine.id)
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            // The toggle goes to the key window's responder chain.
            MainWindow.show()
            if let width = Double(environment["TAMIO_BENCH_WIDTH"] ?? ""), let window = Mac.mainWindow {
                var frame = window.frame
                frame.size.width = width
                window.setFrame(frame, display: true)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            let router = AppRouter.shared
            for page in pages.split(separator: ",").map(String.init) {
                switch page {
                case "servers": router.route = .servers
                // Nothing in the content column, not even a page's toolbar.
                case "blank": router.route = .terminal(UUID())
                case "settings": router.route = .settings
                case "terminal":
                    guard let context = TerminalManager.shared.sessionContexts.first else { continue }
                    router.route = .terminal(context.id)
                default: router.route = .home
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                var collapse: [Double] = [], expand: [Double] = []
                var collapseHitch: [Double] = [], expandHitch: [Double] = []
                for _ in 0 ..< 5 {
                    collapse.append(await settle(for: 0.8) { toggleSidebar() })
                    collapseHitch.append(longest)
                    NSLog("BENCH %@ collapse stretches %@", page, stretches)
                    let collapsed = sidebarWidth()
                    let frames = FrameGaps()
                    frames.start()
                    // The sidebar's width at every 4 ms of the slide, and when
                    // the columnVisibility binding changes: a jump in the widths
                    // at that moment is the slide being cut short.
                    let began = CACurrentMediaTime()
                    var widths: [(Double, CGFloat)] = []
                    var bindingChanged = ""
                    let sampler = Timer(timeInterval: 0.004, repeats: true) { _ in
                        MainActor.assumeIsolated { widths.append((CACurrentMediaTime() - began, sidebarWidth())) }
                    }
                    RunLoop.main.add(sampler, forMode: .common)
                    let watch = router.$sidebarOpen.dropFirst().sink { value in
                        bindingChanged += String(format: " +%.0fms:%@", (CACurrentMediaTime() - began) * 1000, value ? "open" : "hidden")
                    }
                    expand.append(await settle(for: 0.8) { toggleSidebar() })
                    sampler.invalidate(); watch.cancel()
                    expandHitch.append(longest)
                    NSLog("BENCH %@ expand stretches %@", page, stretches)
                    var steps: [String] = []
                    var jumps: [String] = []
                    for (a, b) in zip(widths, widths.dropFirst()) {
                        if b.1 != a.1 { steps.append(String(format: "+%.0f:%.0f", b.0 * 1000, b.1)) }
                        if abs(b.1 - a.1) > 30 { jumps.append(String(format: "+%.0fms %.0f→%.0f", b.0 * 1000, a.1, b.1)) }
                    }
                    NSLog("BENCH %@ expand widths %@", page, steps.joined(separator: " "))
                    NSLog("BENCH %@ expand jumps %@ | binding changed%@", page, jumps.isEmpty ? "none" : jumps.joined(separator: " "), bindingChanged.isEmpty ? " never" : bindingChanged)
                    NSLog("BENCH %@ expand frames %@", page, frames.stop())
                    NSLog("BENCH %@ sidebar width collapsed %.0f expanded %.0f", page, collapsed, sidebarWidth())
                }
                report("\(page) collapse busy", collapse)
                report("\(page) collapse hitch", collapseHitch)
                report("\(page) expand busy", expand)
                report("\(page) expand hitch", expandHitch)
            }
            NSLog("BENCH done")
        }

        /// The frames the window actually showed: each display-link tick's
        /// timestamp, so a frame the screen missed shows as a gap.
        @MainActor
        final class FrameGaps: NSObject {
            private var link: CADisplayLink?
            private var stamps: [CFTimeInterval] = []
            private var began = CACurrentMediaTime()

            func start() {
                guard let view = Mac.mainWindow?.contentView else { return }
                began = CACurrentMediaTime()
                let link = view.displayLink(target: self, selector: #selector(tick(_:)))
                link.add(to: .main, forMode: .common)
                self.link = link
            }

            @objc private func tick(_ link: CADisplayLink) { stamps.append(link.timestamp) }

            /// "interval / gaps over 1.5 intervals, as +start:length ms".
            func stop() -> String {
                link?.invalidate()
                guard stamps.count > 2 else { return "no frames" }
                let deltas = zip(stamps, stamps.dropFirst()).map { $1 - $0 }
                let interval = deltas.sorted()[deltas.count / 2]
                let gaps = zip(stamps, deltas).filter { $1 > interval * 1.5 }
                    .map { String(format: "+%.0f:%.0fms", ($0 - began) * 1000, $1 * 1000) }
                return String(format: "%d frames, interval %.1f ms, gaps: ", stamps.count, interval * 1000) + (gaps.isEmpty ? "none" : gaps.joined(separator: " "))
            }
        }

        /// The width of the split view's first pane, 0 when the sidebar is away.
        private static func sidebarWidth() -> CGFloat {
            func split(in view: NSView) -> NSSplitView? {
                if let split = view as? NSSplitView { return split }
                for child in view.subviews { if let found = split(in: child) { return found } }
                return nil
            }
            guard let content = Mac.mainWindow?.contentView, let split = split(in: content),
                  let first = split.arrangedSubviews.first
            else { return -1 }
            return split.isSubviewCollapsed(first) ? 0 : first.frame.width
        }

        private static func logPanes(_ delay: Double) {
            func split(in view: NSView) -> NSSplitView? {
                if let split = view as? NSSplitView { return split }
                for child in view.subviews { if let found = split(in: child) { return found } }
                return nil
            }
            guard let content = Mac.mainWindow?.contentView, let split = split(in: content) else { return }
            let panes = split.arrangedSubviews.map { String(format: "x %.0f w %.0f", $0.frame.minX, $0.frame.width) }.joined(separator: " | ")
            NSLog("BENCH panes +%.2fs window %.0f: %@", delay, Mac.mainWindow?.frame.width ?? 0, panes)
        }

        private static func toggleSidebar() {
            AppRouter.shared.toggleSidebar()
            if ProcessInfo.processInfo.environment["TAMIO_BENCH_TOOLBAR"] != nil {
                // Every step of the slide: which items still fit, and the
                // search field's width (narrow when it has collapsed).
                var last = ""
                let start = CACurrentMediaTime()
                let timer = Timer(timeInterval: 0.008, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        guard let toolbar = Mac.mainWindow?.toolbar else { return }
                        let visible = (toolbar.visibleItems ?? []).map { item -> String in
                            if let search = item as? NSSearchToolbarItem {
                                return "search(\(Int(search.searchField.frame.width)) pref \(Int(search.preferredWidthForSearchField)))"
                            }
                            return item.itemIdentifier.rawValue.split(separator: ".").last.map(String.init) ?? "?"
                        }
                        var line = "\(visible.count) of \(toolbar.items.count): " + visible.joined(separator: " ")
                        if ProcessInfo.processInfo.environment["TAMIO_BENCH_TOOLBAR"] == "frames", let window = Mac.mainWindow {
                            // Where each item sits in the window, and the room the toolbar has.
                            func frame(_ item: NSToolbarItem) -> String {
                                guard let view = item.view, let superview = view.superview else { return "-" }
                                let rect = superview.convert(view.frame, to: nil)
                                return String(format: "%.0f+%.0f", rect.minX, rect.width)
                            }
                            line += " | window \(Int(window.frame.width)) sidebar \(Int(sidebarWidth())) | "
                            line += toolbar.items.map { item in
                                let name = item.itemIdentifier.rawValue.split(separator: ".").last.map { String($0.prefix(6)) } ?? "?"
                                return "\(name)@\(frame(item))"
                            }.joined(separator: " ")
                        }
                        if line != last {
                            NSLog("BENCH toolbar +%.0f ms %@", (CACurrentMediaTime() - start) * 1000, line)
                            last = line
                        }
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { timer.invalidate() }
            }
            if ProcessInfo.processInfo.environment["TAMIO_BENCH_PANES"] != nil {
                for delay in [0.03, 0.08, 0.15, 0.4] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { logPanes(delay) } }
                }
            }
        }

        static func report(_ name: String, _ samples: [Double]) {
            let sorted = samples.sorted()
            let median = sorted[sorted.count / 2]
            NSLog("BENCH %@ median %.2f ms  max %.2f ms  n=%d", name, median, sorted.last ?? 0, samples.count)
        }

        /// A Files page with no server behind it, to be filled by hand.
        static func emptyFilesPage() async -> FileTransferContext {
            let machine = RDMachine(remoteAddress: "203.0.113.10", remotePort: "22", name: "web-01")
            let context = FileTransferContext(machine: machine)
            FileTransferManager.shared.transfers.append(context)
            AppRouter.shared.route = .transfer(context.id)
            // Once the connection attempt has given up.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            while context.processConnection { try? await Task.sleep(nanoseconds: 200_000_000) }
            try? await Task.sleep(nanoseconds: 500_000_000)
            context.connected = true
            context.isProgressRunning = false
            try? await Task.sleep(nanoseconds: 500_000_000)
            return context
        }

        /// A folder of sample entries: launch with TAMIO_PREVIEW_FILES=1 to check
        /// the table's layout.
        static func previewFiles() async {
            let context = await emptyFilesPage()
            context.currentDir = "/var/log"
            let base = URL(fileURLWithPath: "/var/log")
            let names = ["nginx", "journal", "apt", "private", "auth.log", "syslog", "kern.log", "dpkg.log", "boot.log",
                         "a-very-long-file-name-that-does-not-fit-in-the-name-column-of-the-table-and-is-truncated-in-the-middle-2026-10-11.log.gz",
                         "fail2ban.log", "alternatives.log", "cloud-init.log", "wtmp", "btmp", "lastlog", "ufw.log", "mail.log"]
            context.currentFileList = names.enumerated().map { index, name in
                let file = NSRemoteFile(filename: name)
                var attributes = LIBSSH2_SFTP_ATTRIBUTES()
                attributes.flags = 0xF
                attributes.filesize = UInt64(index * index * 4321 + 17)
                attributes.uid = index < 4 ? 0 : 1000
                attributes.gid = 0
                attributes.permissions = index < 4 ? 0o040755 : 0o100644
                attributes.mtime = UInt(1_780_000_000 + index * 86400 * 3)
                attributes.atime = attributes.mtime
                file.populateAttributes(attributes)
                return FileTransferContext.RemoteFile(base: base, name: name, fstat: file)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            NotificationCenter.default.post(name: .benchFiles, object: nil, userInfo: ["select": 6])
        }

        static func files(_ count: Int) async {
            let context = await emptyFilesPage()

            let base = URL(fileURLWithPath: "/var/log")
            var generator = SystemRandomNumberGenerator()
            let list = (0 ..< count).map { _ in
                let name = "file-\(Int.random(in: 0 ..< 10_000_000, using: &generator)).log"
                return FileTransferContext.RemoteFile(base: base, name: name, fstat: NSRemoteFile(filename: name))
            }
            report("show \(count)", [await settle { context.currentFileList = list }])
            try? await Task.sleep(nanoseconds: 500_000_000)

            var samples: [Double] = []
            for index in 0 ..< 6 {
                samples.append(await settle {
                    context.currentDir = "/var/log/\(index)"
                    context.currentFileList = list.shuffled()
                })
            }
            report("enter folder", samples)

            samples = []
            for index in 0 ..< 20 {
                samples.append(await settle {
                    NotificationCenter.default.post(name: .benchFiles, object: nil, userInfo: ["select": index % 12])
                })
            }
            report("select", samples)

            samples = []
            for index in 0 ..< 20 {
                samples.append(await settle { context.currentSpeed = 1000 + index })
            }
            report("progress tick", samples)

            samples = []
            for text in Array(repeating: ["1", "12", "123", "12", "1", ""], count: Int(ProcessInfo.processInfo.environment["TAMIO_BENCH_REPEAT"] ?? "1") ?? 1).flatMap({ $0 }) {
                samples.append(await settle {
                    NotificationCenter.default.post(name: .benchFiles, object: nil, userInfo: ["filter": text])
                })
            }
            report("filter keystroke", samples)

            try? await Task.sleep(nanoseconds: 1_000_000_000)
            report("idle 0.4 s", [await settle {}, await settle {}, await settle {}])
            await scroll()
            NSLog("BENCH done")
        }

        /// Opens Settings, goes through its categories and scrolls the longest.
        static func settings() async {
            let router = AppRouter.shared
            router.settingsSelection = "general"
            report("open settings", [await settle { router.route = .settings }])
            report("open settings hitch", [longest])
            try? await Task.sleep(nanoseconds: 500_000_000)
            let ids = ["general", "connection", "text", "colors", "cursor", "window", "input", "keyboard", "advanced", "about"]
            var samples: [Double] = []
            var hitches: [Double] = []
            let rounds = Int(ProcessInfo.processInfo.environment["TAMIO_BENCH_REPEAT"] ?? "2") ?? 2
            for id in Array(repeating: ids, count: rounds).flatMap({ $0 }) {
                let sample = await settle { router.settingsSelection = id }
                NSLog("BENCH category %@ %.2f ms  hitch %.2f ms", id, sample, longest)
                samples.append(sample)
                hitches.append(longest)
            }
            report("switch category", samples)
            report("switch category hitch", hitches)
            await edits()
            var reopen: [Double] = []
            // TAMIO_BENCH_BLANK leaves for a page with nothing on it, so what
            // is measured is Settings going and coming and nothing else.
            let away: Route = ProcessInfo.processInfo.environment["TAMIO_BENCH_BLANK"] != nil ? .terminal(UUID()) : .servers
            var leave: [Double] = []
            var leaveHitch: [Double] = []
            var reopenHitch: [Double] = []
            for _ in 0 ..< (Int(ProcessInfo.processInfo.environment["TAMIO_BENCH_REOPEN"] ?? "3") ?? 3) {
                leave.append(await settle { router.route = away })
                leaveHitch.append(longest)
                reopen.append(await settle { router.route = .settings })
                reopenHitch.append(longest)
            }
            if ProcessInfo.processInfo.environment["TAMIO_BENCH_NOPLACES"] == nil { await places() }
            report("leave settings", leave)
            report("leave settings hitch", leaveHitch)
            report("reopen settings", reopen)
            report("reopen settings hitch", reopenHitch)
            router.settingsSelection = "advanced"
            try? await Task.sleep(nanoseconds: 800_000_000)
            report("idle 0.4 s", [await settle {}, await settle {}, await settle {}])
            await scroll()
            router.settingsSelection = "colors"
            try? await Task.sleep(nanoseconds: 800_000_000)
            await scroll()
            NSLog("BENCH done")
        }

        /// Goes between the places of the sidebar that are not Settings.
        static func places() async {
            let router = AppRouter.shared
            var samples: [Double] = []
            var hitches: [Double] = []
            for route in [Route.home, .servers, .identities, .snippets, .home, .servers, .identities, .snippets] {
                let sample = await settle { router.route = route }
                NSLog("BENCH place %@ %.2f ms  hitch %.2f ms", String(describing: route), sample, longest)
                samples.append(sample)
                hitches.append(longest)
            }
            report("change place", samples)
            report("change place hitch", hitches)
        }

        /// Changes a setting again and again, as dragging its control would,
        /// then puts back what it had.
        static func edits() async {
            let router = AppRouter.shared
            router.settingsSelection = "cursor"
            try? await Task.sleep(nanoseconds: 800_000_000)
            let key = "cursor-opacity"
            let before = ConfigBenchmark.value(key)
            var samples: [Double] = []
            var hitches: [Double] = []
            let count = Int(ProcessInfo.processInfo.environment["TAMIO_BENCH_EDITS"] ?? "12") ?? 12
            for step in 0 ..< count {
                let value = String(format: "%.2f", 0.4 + Double(step % 6) * 0.1)
                samples.append(await settle { ConfigBenchmark.edit(key, value) })
                hitches.append(longest)
            }
            report("edit a setting", samples)
            report("edit a setting hitch", hitches)
            ConfigBenchmark.edit(key, before)
            try? await Task.sleep(nanoseconds: 800_000_000)
        }

        /// The main window as on screen. CGWindowListCreateImage, which Swift
        /// no longer offers by name; a window of its own needs no permission.
        static func snapshot(_ path: String) {
            typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
            guard let window = Mac.mainWindow,
                  let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage")
            else { return NSLog("BENCH snapshot: no window") }
            // TAMIO_PREVIEW_SNAPSHOT_DESKTOP: with what is behind the window
            // (the desktop picture, without screen recording), to see glass.
            let desktop = ProcessInfo.processInfo.environment["TAMIO_PREVIEW_SNAPSHOT_DESKTOP"] != nil
            let top = NSScreen.screens.first?.frame.height ?? 0
            let rect = CGRect(x: window.frame.minX, y: top - window.frame.maxY, width: window.frame.width, height: window.frame.height)
            guard let image = unsafeBitCast(symbol, to: Capture.self)(
                desktop ? rect : .null, desktop ? (1 << 2 | 1 << 3) : 1 << 3, UInt32(window.windowNumber), desktop ? 8 : 1 | 8
            )?.takeRetainedValue()
            else { return NSLog("BENCH snapshot: no image") }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            NSLog("BENCH snapshot %@", path)
        }

        /// Scrolls Home's cards or the Servers list ("home,servers") from top
        /// to bottom and back, with the pointer over the page as it is when
        /// someone scrolls with a trackpad, so every hover region under it is
        /// tested at each frame. TAMIO_BENCH_SERVERS=<n> tops the store up to
        /// n servers no one answers at (for a copy of the app with its own
        /// store only), TAMIO_BENCH_LIVE=1 gives them made-up readings.
        static func pageScroll(_ pages: String) async {
            let environment = ProcessInfo.processInfo.environment
            let servers = Int(environment["TAMIO_BENCH_SERVERS"] ?? "") ?? 0
            let existing = TamioStore.shared.machineGroup.machines.count
            if servers > existing {
                LiveStatusCenter.shared.isEnabled = false
                for index in existing ..< servers {
                    TamioStore.shared.machineGroup.insert(RDMachine(
                        remoteAddress: "203.0.113.\(index % 250 + 1)", remotePort: "22", name: "bench-\(index + 1)", group: index % 3 == 0 ? "Web" : "DB"
                    ))
                }
            }
            if environment["TAMIO_BENCH_LIVE"] != nil { LiveStatusCenter.shared.installPreviews() }
            MainWindow.show()
            for page in pages.split(separator: ",").map(String.init) {
                AppRouter.shared.route = page == "servers" ? .servers : .home
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                for round in 0 ..< 2 {
                    if let window = Mac.mainWindow, let content = window.contentView, let scroller = largestScrollView(in: content) {
                        let rect = scroller.convert(scroller.bounds, to: nil)
                        let center = window.convertPoint(toScreen: NSPoint(x: rect.midX, y: rect.midY))
                        // CoreGraphics counts from the top of the main screen.
                        let height = NSScreen.screens.first?.frame.height ?? 0
                        CGWarpMouseCursorPosition(CGPoint(x: center.x, y: height - center.y))
                    }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    await scroll(label: "\(page) #\(round + 1)")
                }
            }
            NSLog("BENCH done")
        }

        /// Scrolls the file list from top to bottom and back at a steady pace
        /// and reports how long frames took.
        static func scroll(label: String = "") async {
            guard let window = Mac.mainWindow, let content = window.contentView,
                  let scroller = largestScrollView(in: content)
            else { return NSLog("BENCH scroll: no scroll view") }
            let height = scroller.documentView?.frame.height ?? 0
            NSLog("BENCH scroll view %@ content %.0f", String(describing: type(of: scroller)), height)
            let recorder = FrameRecorder()
            // A fast flick, about 6000 pt a second, rather than the whole list.
            let distance = min(12000, max(0, height - scroller.contentView.bounds.height))
            let duration = 4.0
            recorder.start(in: content) { progress in
                // There and back.
                let phase = progress < 0.5 ? progress * 2 : (1 - progress) * 2
                scroller.contentView.scroll(to: NSPoint(x: 0, y: distance * phase))
                scroller.reflectScrolledClipView(scroller.contentView)
            }
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            let frames = recorder.stop()
            guard frames.count > 2 else { return }
            let sorted = frames.sorted()
            let slow = frames.filter { $0 > 1000.0 / 60 * 1.5 }.count
            NSLog(
                "BENCH scroll %@ %.0f pt  frames %d  median %.2f ms  p95 %.2f ms  max %.2f ms  slow(>25ms) %d",
                label, distance, frames.count, sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.95)], sorted.last ?? 0, slow
            )
        }

        private static func largestScrollView(in view: NSView) -> NSScrollView? {
            var best: NSScrollView?
            var stack = [view]
            while let next = stack.popLast() {
                if let scroll = next as? NSScrollView,
                   (scroll.documentView?.frame.height ?? 0) > (best?.documentView?.frame.height ?? 0)
                {
                    best = scroll
                }
                stack.append(contentsOf: next.subviews)
            }
            return best
        }
    }

    @MainActor
    private final class FrameRecorder: NSObject {
        private var link: CADisplayLink?
        private var step: ((Double) -> Void)?
        private var begin = 0.0
        private var last = 0.0
        private var frames: [Double] = []
        private var duration = 4.0

        func start(in view: NSView, duration: Double = 4, step: @escaping (Double) -> Void) {
            self.step = step
            self.duration = duration
            link = view.displayLink(target: self, selector: #selector(tick))
            link?.add(to: .main, forMode: .common)
        }

        @objc private func tick(_: CADisplayLink) {
            // Wall time between callbacks: a stalled main thread shows as a long frame.
            let now = CACurrentMediaTime()
            if begin == 0 { begin = now } else { frames.append((now - last) * 1000) }
            last = now
            step?(min(1, (now - begin) / duration))
        }

        func stop() -> [Double] {
            link?.invalidate()
            return frames
        }
    }
#endif
