//
//  OverlayManager.swift
//  Callsign
//

import AppKit
import Darwin
import os
import SwiftUI

// The probe's view of the overlays, so tests can record badges without opening panels.
protocol BadgeSink {
    func show(_ badges: [AppBadge], configuration: TagConfiguration, animated: Bool)
    func hide()
}

final class OverlayManager: BadgeSink {
    private(set) var panels: [CGWindowID: BadgePanel] = [:]
    private var liquidGlass = false
    private var space: OverlaySpace?
    // Creation is retried on each show; log once per failing streak, not per badge update.
    private var spaceFailed = false

    func show(
        _ badges: [AppBadge],
        configuration: TagConfiguration,
        animated: Bool
    ) {
        // Recreate only when changing window classes, so Glass-off uses unmodified AppKit behavior.
        if liquidGlass != configuration.liquidGlass {
            panels.values.forEach { $0.window.close() }
            panels.removeAll()
            liquidGlass = configuration.liquidGlass
        }
        // Late titles and WindowServer reordering must not move a visible tag to another panel.
        let ids = Set(badges.map(\.windowID))
        for (id, panel) in panels where !ids.contains(id) {
            panel.window.close()
            panels.removeValue(forKey: id)
        }
        guard !badges.isEmpty else { hide(); return }
        let needsSpace = space == nil
        if needsSpace {
            space = OverlaySpace()
            if space == nil, !spaceFailed {
                Log.overlay.error("Overlay Space creation failed; falling back to moveToActiveSpace")
            }
            spaceFailed = space == nil
        }
        for badge in badges {
            let panel = panels[badge.windowID] ?? BadgePanel(liquidGlass: liquidGlass)
            panels[badge.windowID] = panel
            let behavior = panel.window.collectionBehavior.subtracting(.moveToActiveSpace)
                .union(space == nil ? .moveToActiveSpace : [])
            if panel.window.collectionBehavior != behavior { panel.window.collectionBehavior = behavior }
            let wasVisible = panel.window.isVisible
            let previousFrame = panel.window.frame
            panel.show(badge, configuration: configuration, animated: animated)
            if needsSpace || !wasVisible || panel.window.frame != previousFrame {
                space?.add(panel.window)
            }
        }
    }

    func hide() {
        panels.values.forEach { $0.hide() }
        space = nil
    }
}

// Desktop previews include ordinary overlay windows, even with sharingType = .none.
// ponytail: private SkyLight space; fall back to the active desktop if unavailable.
// Replace this with AppKit preview exclusion if Apple exposes it.
private final class OverlaySpace {
    private let skyLight: PrivateAPI.SkyLight
    private let connection: Int32
    private let id: UInt64

    init?() {
        guard let skyLight = PrivateAPI.skyLight else { return nil }
        self.skyLight = skyLight
        connection = skyLight.mainConnectionID()
        id = skyLight.spaceCreate(connection, 1, nil)
        guard id != 0 else { return nil }
        skyLight.spaceSetAbsoluteLevel(connection, id, 0)
        skyLight.showSpaces(connection, [id] as CFArray)
    }

    func add(_ window: NSWindow) {
        // 0x7 removes membership in desktop/full-screen Spaces, not just the inactive ones.
        skyLight.spaceAddWindowsAndRemoveFromSpaces(connection, id, [window.windowNumber] as CFArray, 0x7)
    }

    deinit { skyLight.spaceDestroy(connection, id) }
}

private final class GlassBadgeWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // Keep native glass active without taking focus; never swizzle NSWindow globally.
    // ponytail: private AppKit hook; replace when a public glass-active override is available.
    @objc(_hasActiveAppearance)
    nonisolated func glassHasActiveAppearance() -> Bool { true }
}

final class BadgePanel {
    let window: NSPanel
    private let hostingView: NSHostingView<BadgeView>
    private var representedPID: pid_t = -1
    private var representedText: String?
    private var representedConfiguration: TagConfiguration?

    init(liquidGlass: Bool) {
        let placeholder = NSImage(
            systemSymbolName: "app.fill",
            accessibilityDescription: nil) ?? NSImage(size: NSSize(width: 32, height: 32))
        hostingView = NSHostingView(rootView: BadgeView(
            icon: placeholder,
            text: "App",
            configuration: TagConfiguration(liquidGlass: liquidGlass)))
        // We size the panel explicitly; only intrinsic sizing is needed for fittingSize.
        hostingView.sizingOptions = [.intrinsicContentSize]
        // macOS 26 fills the active glass window's content rect with a backdrop; clip it to the pill.
        if liquidGlass {
            hostingView.wantsLayer = true
            hostingView.layer?.masksToBounds = true
        }
        if liquidGlass {
            window = GlassBadgeWindow(
                contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false)
        } else {
            window = NSPanel(
                contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false)
        }
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        window.level = .popUpMenu
        window.collectionBehavior = [
            // Fallback if the dedicated overlay Space cannot be created.
            .moveToActiveSpace,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
    }

    func show(
        _ badge: AppBadge,
        configuration: TagConfiguration,
        animated: Bool
    ) {
        let text = configuration.label.text(appName: badge.appName, windowTitle: badge.windowTitle)

        if representedPID != badge.pid
            || representedText != text
            || representedConfiguration != configuration {
            representedPID = badge.pid
            representedText = text
            representedConfiguration = configuration
            hostingView.rootView = BadgeView(
                icon: badge.icon,
                text: text,
                configuration: configuration)
            let fittingSize = hostingView.fittingSize
            hostingView.frame = NSRect(origin: .zero, size: NSSize(
                width: min(max(fittingSize.width, 44 * configuration.scale), 300 * configuration.scale),
                height: max(fittingSize.height, 38 * configuration.scale)))
            // Same radius as BadgeView's shape.
            hostingView.layer?.cornerRadius = 11 * configuration.scale
        }

        let size = hostingView.frame.size
        let axOrigin = configuration.badgeOrigin(thumbnail: badge.thumbnailFrame, badgeSize: size)
        // AX uses top-left coordinates; AppKit uses bottom-left. Flip around the primary display.
        let primaryScreenTop = NSScreen.screens.first?.frame.maxY ?? 0
        let frame = NSRect(
            x: axOrigin.x,
            y: primaryScreenTop - axOrigin.y - size.height,
            width: size.width,
            height: size.height)
        if window.frame != frame { window.setFrame(frame, display: true) }
        // A dedicated overlay Space is visible but is not an active desktop Space.
        let needsOrdering = !window.isVisible
            || (window.collectionBehavior.contains(.moveToActiveSpace) && !window.isOnActiveSpace)
        let appearing = animated || needsOrdering
        let shouldFade = appearing && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if appearing { window.alphaValue = shouldFade ? 0 : 1 }
        if needsOrdering { window.orderFrontRegardless() }
        if shouldFade {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                window.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        window.orderOut(nil)
        window.alphaValue = 0
    }
}

struct BadgeView: View {
    let icon: NSImage
    let text: String?
    let configuration: TagConfiguration

    var glassMaterial: Glass {
        configuration.liquidGlass ? .regular : .identity
    }

    var textColor: Color {
        configuration.liquidGlass ? .primary : Color(
            .sRGB,
            red: configuration.textRed,
            green: configuration.textGreen,
            blue: configuration.textBlue,
            opacity: configuration.textAlpha)
    }

    var body: some View {
        let scale = configuration.scale
        let shape = RoundedRectangle(cornerRadius: 11 * scale)
        let background = Color(
            .sRGB,
            red: configuration.red,
            green: configuration.green,
            blue: configuration.blue,
            opacity: configuration.alpha)

        HStack(spacing: 7 * scale) {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 26 * scale, height: 26 * scale)
            if let text {
                Text(text)
                    .font(.system(size: 13 * scale, weight: .semibold))
                    .foregroundStyle(textColor)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 9 * scale)
        .padding(.vertical, 6 * scale)
        .background {
            if !configuration.liquidGlass {
                ZStack {
                    shape.fill(.regularMaterial)
                    shape.fill(background)
                    shape.stroke(.primary.opacity(0.18), lineWidth: 0.75)
                }
            }
        }
        .glassEffect(glassMaterial, in: shape)
        .fixedSize()
    }
}
