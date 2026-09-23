//
//  OverlayManager.swift
//  Callsign
//

import AppKit
import SwiftUI

@MainActor
final class OverlayManager {
    private(set) var panels: [CGWindowID: BadgePanel] = [:]
    private var liquidGlass = false

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
        for badge in badges {
            let panel = panels[badge.windowID] ?? BadgePanel(liquidGlass: liquidGlass)
            panels[badge.windowID] = panel
            panel.show(badge, configuration: configuration, animated: animated)
        }
    }

    func hide() {
        panels.values.forEach { $0.hide() }
    }
}

@MainActor
private final class GlassBadgeWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // Keep native glass active without taking focus; never swizzle NSWindow globally.
    // ponytail: private AppKit hook; replace when a public glass-active override is available.
    @objc(_hasActiveAppearance)
    nonisolated func glassHasActiveAppearance() -> Bool { true }
}

@MainActor
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
            .canJoinAllSpaces,
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
        let appearing = animated || !window.isVisible
        let shouldFade = appearing && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if appearing { window.alphaValue = shouldFade ? 0 : 1 }
        if !window.isVisible { window.orderFrontRegardless() }
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
