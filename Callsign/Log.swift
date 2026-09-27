//
//  Log.swift
//  Callsign
//

import os

nonisolated enum Log {
    private static let subsystem = "com.shylee.Callsign"
    static let detection = Logger(subsystem: subsystem, category: "detection")
    static let titles = Logger(subsystem: subsystem, category: "titles")
    static let overlay = Logger(subsystem: subsystem, category: "overlay")
    static let privateAPI = Logger(subsystem: subsystem, category: "privateAPI")
    static let signposter = OSSignposter(logger: detection)
}
