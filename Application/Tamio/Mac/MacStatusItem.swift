//
//  MacStatusItem.swift
//  Tamio (macOS)
//
//  One menu bar item: an animated image, a two-line title, and a popover
//  whose content is SwiftUI's, on the window material.
//

import AppKit
import SwiftUI

@MainActor
final class MacStatusItem: NSObject, NSPopoverDelegate {
    /// Every item there is, for the appearance to reach their popovers.
    static let live = NSHashTable<MacStatusItem>.weakObjects()

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let frames: [NSImage]
    let idleFrame: NSImage?
    let onClick: () -> Void
    /// Shows the main window; the item's menu offers it with Quit, which a
    /// Tamio that lives only in the menu bar has nowhere else.
    var onOpenApp: (() -> Void)?

    private(set) var popover: NSPopover?
    private var outsideClicks: Any?

    private var frameIndex = 0
    private var interval: Double = 0
    private var timer: Timer?

    init(toolTip: String, frames: [NSImage], idleFrame: NSImage?, onClick: @escaping () -> Void) {
        self.frames = frames.map(Self.template)
        self.idleFrame = idleFrame.map(Self.template)
        self.onClick = onClick
        super.init()
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.imagePosition = .imageLeading
        item.button?.toolTip = toolTip
        item.button?.image = self.idleFrame
        Self.live.add(self)
    }

    /// Drawn in the menu bar's colour, 18 points tall.
    private static func template(_ image: NSImage) -> NSImage {
        let copy = image.copy() as! NSImage
        copy.isTemplate = true
        if copy.size.height > 0 {
            let height: CGFloat = 18
            copy.size = NSSize(width: copy.size.width * height / copy.size.height, height: height)
        }
        return copy
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp || NSEvent.modifierFlags.contains(.control) {
            showMenu()
        } else {
            onClick()
        }
    }

    private func showMenu() {
        close()
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Open Tamio"), action: #selector(openApp), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit Tamio"), action: #selector(quit), keyEquivalent: "q").target = self
        // Shown for this click only, so a left click still opens the popover.
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func openApp() {
        onOpenApp?()
    }

    @objc private func quit() {
        // The termination guard may ask first; its alert needs Tamio in front.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.terminate(nil)
    }

    func remove() {
        timer?.invalidate()
        stopWatchingOutsideClicks()
        popover?.close()
        NSStatusBar.system.removeStatusItem(item)
        Self.live.remove(self)
    }

    // MARK: Image and title

    func update(title: String, frameInterval: Double) {
        guard let button = item.button else { return }
        if title.isEmpty {
            button.attributedTitle = NSAttributedString(string: "")
        } else {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .right
            paragraph.maximumLineHeight = 10
            paragraph.minimumLineHeight = 10
            button.attributedTitle = NSAttributedString(
                string: title,
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
                    .paragraphStyle: paragraph,
                    .baselineOffset: -5,
                ]
            )
        }
        guard frameInterval != interval else { return }
        interval = frameInterval
        timer?.invalidate()
        timer = nil
        guard frameInterval > 0, !frames.isEmpty else {
            button.image = idleFrame
            return
        }
        let timer = Timer(timeInterval: frameInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.nextFrame() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        nextFrame()
    }

    private func nextFrame() {
        frameIndex = (frameIndex + 1) % frames.count
        item.button?.image = frames[frameIndex]
    }

    // MARK: Popover

    /// Gives the popover its content, `width` wide and as tall as it needs.
    func setContent(_ content: some View, width: CGFloat) {
        let hosting = NSHostingController(rootView: content)
        let size = hosting.sizeThatFits(in: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        let contentSize = NSSize(width: width, height: min(size.height, 900))
        hosting.view.frame = NSRect(origin: .zero, size: contentSize)
        hosting.view.autoresizingMask = [.width, .height]

        let holder = NSView(frame: NSRect(origin: .zero, size: contentSize))
        // As in an AppKit popover, whose window is never the main one: the
        // material at rest, whichever app is in front.
        let backdrop = Mac.makeBackdrop(frame: holder.bounds)
        backdrop.state = .inactive
        holder.addSubview(backdrop)
        holder.addSubview(hosting.view)

        let controller = NSViewController()
        controller.view = holder
        controller.addChild(hosting)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = contentSize
        popover.contentViewController = controller
        popover.delegate = self
        self.popover = popover
    }

    func toggle() {
        guard let popover else { return }
        if popover.isShown { close() } else { show() }
    }

    func show() {
        guard let popover, let button = item.button else { return }
        // A menu bar popover takes the menu bar's appearance, which follows the
        // wallpaper; use Tamio's Light / Dark / System choice instead so the
        // cards look as they do in the window.
        popover.appearance = NSApp.appearance ?? NSApp.effectiveAppearance
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func close() {
        popover?.performClose(nil)
        stopWatchingOutsideClicks()
    }

    nonisolated func popoverDidClose(_: Notification) {
        MainActor.assumeIsolated {
            stopWatchingOutsideClicks()
            // The popover must not keep the keyboard once it closes.
            if NSApp.isActive, NSApp.keyWindow == nil { Mac.mainWindow?.makeKey() }
        }
    }

    private func stopWatchingOutsideClicks() {
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
    }
}
