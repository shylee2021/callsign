//
//  OverlayManager.swift
//  Callsign
//

import AppKit
import SwiftUI

@MainActor
final class SceneProbe {
    private let window: NSPanel
    private var expectedFrame = CGRect.zero

    init() {
        window = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.sharingType = .none
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.ignoresMouseEvents = true
        window.alphaValue = 0
        window.level = .popUpMenu
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
    }

    func show() {
        guard let screen = NSScreen.screens.first else { return }
        expectedFrame = CGRect(x: 0, y: 0, width: screen.frame.width, height: screen.frame.height)
        window.setFrame(expectedFrame, display: false)
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }

    func isAtRest() -> Bool? {
        guard window.windowNumber > 0,
              let entries = CGWindowListCopyWindowInfo(
                .optionIncludingWindow,
                CGWindowID(window.windowNumber)) as? [[String: Any]],
              let bounds = entries.first?[kCGWindowBounds as String] as? [String: Any]
        else { return nil }

        let actual = CGRect(
            x: number(bounds["X"]),
            y: number(bounds["Y"]),
            width: number(bounds["Width"]),
            height: number(bounds["Height"]))
        return abs(actual.minX - expectedFrame.minX) <= 5
            && abs(actual.minY - expectedFrame.minY) <= 5
            && abs(actual.width - expectedFrame.width) <= 5
            && abs(actual.height - expectedFrame.height) <= 5
    }

    private func number(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }
}

@MainActor
final class OverlayManager {
    private var panels: [BadgePanel] = []

    func show(
        _ badges: [AppBadge],
        configuration: TagConfiguration,
        animated: Bool
    ) {
        while panels.count < badges.count {
            panels.append(BadgePanel())
        }
        for (panel, badge) in zip(panels, badges) {
            panel.show(
                badge,
                configuration: configuration,
                animated: animated)
        }
        for panel in panels.dropFirst(badges.count) {
            panel.hide()
        }
    }

    func fadeOut(after delay: Double) {
        panels.forEach { $0.fadeOut(after: delay) }
    }

    func hide() {
        panels.forEach { $0.hide() }
    }
}

@MainActor
private final class BadgePanel {
    private let window: NSPanel
    private let hostingView: NSHostingView<BadgeView>
    private var representedPID: pid_t = -1
    private var representedText: String?
    private var representedConfiguration: TagConfiguration?
    private var fadeTask: Task<Void, Never>?

    init() {
        let placeholder = NSImage(
            systemSymbolName: "app.fill",
            accessibilityDescription: nil) ?? NSImage(size: NSSize(width: 32, height: 32))
        hostingView = NSHostingView(rootView: BadgeView(
            icon: placeholder,
            text: "App",
            configuration: .default))
        window = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
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
        fadeTask?.cancel()
        fadeTask = nil

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
        }

        let fittingSize = hostingView.fittingSize
        let size = NSSize(
            width: min(max(fittingSize.width, 44 * configuration.scale), 300 * configuration.scale),
            height: max(fittingSize.height, 38 * configuration.scale))
        hostingView.frame = NSRect(origin: .zero, size: size)

        let axOrigin = configuration.badgeOrigin(thumbnail: badge.thumbnailFrame, badgeSize: size)
        let primaryScreenTop = NSScreen.screens.first?.frame.maxY ?? 0
        window.setFrame(NSRect(
            x: axOrigin.x,
            y: primaryScreenTop - axOrigin.y - size.height,
            width: size.width,
            height: size.height), display: true)
        let shouldFade = animated || !window.isVisible
        if shouldFade {
            window.alphaValue = 0
        }
        window.orderFrontRegardless()
        if shouldFade {
            DispatchQueue.main.async { [weak window] in
                guard let window, window.isVisible else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    window.animator().alphaValue = 1
                }
            }
        } else if window.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                window.animator().alphaValue = 1
            }
        }
    }

    func fadeOut(after delay: Double) {
        guard window.isVisible, window.alphaValue > 0 else { return }
        fadeTask?.cancel()
        fadeTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(Int(delay * 1_000)))
            } catch { return }
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.08
                self.window.animator().alphaValue = 0
            }
            guard !Task.isCancelled else { return }
            self.window.orderOut(nil)
        }
    }

    func hide() {
        fadeTask?.cancel()
        fadeTask = nil
        window.orderOut(nil)
        window.alphaValue = 0
    }
}

private struct BadgeView: View {
    let icon: NSImage
    let text: String?
    let configuration: TagConfiguration

    var body: some View {
        let scale = configuration.scale
        let shape = RoundedRectangle(cornerRadius: 11 * scale)

        HStack(spacing: 7 * scale) {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 26 * scale, height: 26 * scale)
            if let text {
                Text(text)
                    .font(.system(size: 13 * scale, weight: .semibold))
                    .foregroundStyle(Color(
                        .sRGB,
                        red: configuration.textRed,
                        green: configuration.textGreen,
                        blue: configuration.textBlue,
                        opacity: configuration.textAlpha))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 9 * scale)
        .padding(.vertical, 6 * scale)
        .background {
            ZStack {
                shape.fill(.regularMaterial)
                shape.fill(Color(
                    .sRGB,
                    red: configuration.red,
                    green: configuration.green,
                    blue: configuration.blue,
                    opacity: configuration.alpha))
            }
        }
        .overlay {
            shape.stroke(.primary.opacity(0.18), lineWidth: 0.75)
        }
        .fixedSize()
    }
}
