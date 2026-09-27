//
//  ThumbnailSource.swift
//  Callsign
//

@preconcurrency import ApplicationServices

// Dock accessibility (AX) detects Mission Control on both versions.
// macOS 26 uses Dock AX thumbnails; macOS 27+ uses WindowServer frames.
// On macOS 27, remote titles come from AX; our own titles come directly from AppKit.
protocol ThumbnailSource {
    // Shown in the status line.
    var name: String { get }
    // Whether thumbnail titles come from the window title cache rather than the source itself.
    var usesWindowTitles: Bool { get }
    func thumbnails(
        missionControl: AXUIElement,
        windows: [WindowInfo],
        windowTitles: [pid_t: [CGWindowID: String]]
    ) -> [Thumbnail]
}

func defaultThumbnailSource() -> any ThumbnailSource {
    if #available(macOS 27, *) {
        WindowServerThumbnailSource()
    } else {
        DockThumbnailSource()
    }
}

struct DockThumbnailSource: ThumbnailSource {
    let name = "AX"
    let usesWindowTitles = false

    func thumbnails(
        missionControl: AXUIElement,
        windows: [WindowInfo],
        windowTitles: [pid_t: [CGWindowID: String]]
    ) -> [Thumbnail] {
        Accessibility.children(of: missionControl)
            .filter { Accessibility.string(kAXIdentifierAttribute, of: $0) == "mc.display" }
            .flatMap(Accessibility.children)
            .filter { Accessibility.string(kAXIdentifierAttribute, of: $0) == "mc.windows" }
            .flatMap(Accessibility.children)
            .compactMap { element in
                guard let frame = Accessibility.frame(of: element) else { return nil }
                return Thumbnail(
                    windowID: nil,
                    title: Accessibility.string(kAXTitleAttribute, of: element) ?? "",
                    frame: frame)
            }
    }
}

struct WindowServerThumbnailSource: ThumbnailSource {
    let name = "WindowServer"
    let usesWindowTitles = true

    func thumbnails(
        missionControl: AXUIElement,
        windows: [WindowInfo],
        windowTitles: [pid_t: [CGWindowID: String]]
    ) -> [Thumbnail] {
        // macOS 27 can expose an empty AX group, so do not rely on its children.
        Thumbnail.fromWindowServer(windows, windowTitles: windowTitles)
    }
}
