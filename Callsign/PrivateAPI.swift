//
//  PrivateAPI.swift
//  Callsign
//

@preconcurrency import ApplicationServices
import Darwin

// Every private dependency lives here, so a macOS update has one place to check:
// - _AXUIElementGetWindow: pairs AX windows with WindowServer IDs; Mission Control scales frames,
//   so geometry cannot match remote titles to thumbnails.
// - CGSMainConnectionID, SLSSpaceCreate, SLSSpaceSetAbsoluteLevel, SLSShowSpaces,
//   SLSSpaceAddWindowsAndRemoveFromSpaces, SLSSpaceDestroy: a dedicated overlay Space keeps tags
//   out of desktop previews, which include ordinary overlay windows even with sharingType = .none.
// - -[NSWindow _hasActiveAppearance]: GlassBadgeWindow overrides it to keep glass active without
//   focus. AppKit calls it, so it is not resolved here; a rename silently dims glass tags.
nonisolated enum PrivateAPI {
    typealias AXWindowID = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    struct SkyLight {
        let mainConnectionID: @convention(c) () -> Int32
        let spaceCreate: @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
        let spaceSetAbsoluteLevel: @convention(c) (Int32, UInt64, Int32) -> Void
        let showSpaces: @convention(c) (Int32, CFArray) -> Void
        let spaceAddWindowsAndRemoveFromSpaces: @convention(c) (Int32, UInt64, CFArray, UInt32) -> Void
        let spaceDestroy: @convention(c) (Int32, UInt64) -> Void
    }

    static let symbols = [
        "_AXUIElementGetWindow",
        "CGSMainConnectionID",
        "SLSSpaceCreate",
        "SLSSpaceSetAbsoluteLevel",
        "SLSShowSpaces",
        "SLSSpaceAddWindowsAndRemoveFromSpaces",
        "SLSSpaceDestroy",
    ]

    // Resolved once. Addresses are kept as integers so the table stays Sendable.
    private static let addresses: [String: UInt] = {
        // dlopen(nil) is the main program handle; keep it open for the process lifetime.
        guard let handle = dlopen(nil, RTLD_LAZY) else { return [:] }
        return symbols.reduce(into: [:]) { table, name in
            if let symbol = dlsym(handle, name) { table[name] = UInt(bitPattern: symbol) }
        }
    }()

    private static func function<Function>(_ name: String, as _: Function.Type) -> Function? {
        guard let address = addresses[name].flatMap(UnsafeRawPointer.init(bitPattern:)) else { return nil }
        return unsafeBitCast(address, to: Function.self)
    }

    static let axWindowID = function("_AXUIElementGetWindow", as: AXWindowID.self)

    // All or nothing: a partial Space is worse than the active-desktop fallback.
    static let skyLight: SkyLight? = {
        guard let main = function("CGSMainConnectionID", as: (@convention(c) () -> Int32).self),
              let create = function("SLSSpaceCreate", as: (@convention(c) (Int32, Int32, CFDictionary?) -> UInt64).self),
              let level = function("SLSSpaceSetAbsoluteLevel", as: (@convention(c) (Int32, UInt64, Int32) -> Void).self),
              let show = function("SLSShowSpaces", as: (@convention(c) (Int32, CFArray) -> Void).self),
              let add = function(
                "SLSSpaceAddWindowsAndRemoveFromSpaces",
                as: (@convention(c) (Int32, UInt64, CFArray, UInt32) -> Void).self),
              let destroy = function("SLSSpaceDestroy", as: (@convention(c) (Int32, UInt64) -> Void).self)
        else { return nil }
        return SkyLight(
            mainConnectionID: main,
            spaceCreate: create,
            spaceSetAbsoluteLevel: level,
            showSpaces: show,
            spaceAddWindowsAndRemoveFromSpaces: add,
            spaceDestroy: destroy)
    }()

    static var report: String {
        symbols.map { "\($0): \(addresses[$0] == nil ? "missing" : "resolved")" }
            .joined(separator: "\n")
    }
}
