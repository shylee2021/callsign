//
//  WindowList.swift
//  Callsign
//

import AppKit

struct WindowInfo {
    let id: CGWindowID
    let pid: pid_t
    let owner: String
    let title: String
    let frame: CGRect
    let layer: Int
    let alpha: Double

    var canReceiveBadge: Bool {
        // WindowManager's hover decoration is system UI, even when it appears on layer 0.
        layer == 0 && alpha > 0.01 && owner != "WindowManager"
    }

    func hasWindowTitleResult(in titles: [pid_t: [CGWindowID: String]]) -> Bool {
        // Missing means pending; an empty string means the lookup finished without a title.
        titles[pid]?[id] != nil
    }
}

enum WindowList {
    static func onScreen() -> [WindowInfo] {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID) as? [[String: Any]] else { return [] }

        return windows.compactMap { window in
            guard let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            let id = number(window[kCGWindowNumber as String]).uint32Value
            guard id != kCGNullWindowID, frame.width > 1, frame.height > 1 else { return nil }
            return WindowInfo(
                id: id,
                pid: pid_t(number(window[kCGWindowOwnerPID as String]).int32Value),
                owner: window[kCGWindowOwnerName as String] as? String ?? "?",
                title: window[kCGWindowName as String] as? String ?? "",
                frame: frame,
                layer: number(window[kCGWindowLayer as String]).intValue,
                alpha: number(window[kCGWindowAlpha as String]).doubleValue)
        }
    }

    private static func number(_ value: Any?) -> NSNumber {
        value as? NSNumber ?? 0
    }
}
