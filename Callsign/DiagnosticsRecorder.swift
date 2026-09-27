//
//  DiagnosticsRecorder.swift
//  Callsign
//

@preconcurrency import ApplicationServices
import AppKit
import Observation

@MainActor
@Observable
final class DiagnosticsRecorder {
    private(set) var report = ""
    // Session-only: never save diagnostic recording in preferences.
    var recordDiagnostics = false {
        didSet {
            if !recordDiagnostics { cancel() }
        }
    }

    @ObservationIgnored private var reportTask: Task<Void, Never>?

    func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    func cancel() {
        reportTask?.cancel()
        reportTask = nil
        // Keep the last report in memory so recording can be stopped before reviewing/copying it.
    }

    @discardableResult
    func scheduleReport(_ capture: @escaping @MainActor () -> String) -> Task<Void, Never>? {
        guard recordDiagnostics else { return nil }
        // Poll schedules only after settling; transitions and pause cancel pending captures.
        // Keep the completed task until the next transition: one capture per settled layout.
        if let reportTask { return reportTask }
        let task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch { return }
            guard let self, self.recordDiagnostics, !Task.isCancelled else { return }
            let payload = capture()
            guard self.recordDiagnostics, !Task.isCancelled else { return }
            self.report = "Captured \(Date().formatted(date: .omitted, time: .standard))\n\n\(payload)"
        }
        reportTask = task
        return task
    }

    static func makeReport(
        for missionControl: AXUIElement,
        dockPID: pid_t,
        windows: [WindowInfo],
        settledMilliseconds: Int?
    ) -> String {
        // Cap the diagnostic node budget because AX reads run on the main thread.
        var remaining = 500
        let tree = dumpTree(missionControl, depth: 0, remaining: &remaining)
            .joined(separator: "\n")
        let timing = settledMilliseconds.map { "~\($0) ms from transition detection to settled" } ?? "Not measured"
        return "SETTLE TIMING\n\(timing) (2 unchanged polls: ~66 ms after entry or a move, 33–133 ms after a Space change; \(MissionControlProbe.activePollDelay) ms poll delay + API overhead)\nDetection: Dock Accessibility, window geometry and Space notifications. No global input monitoring.\n\nMISSION CONTROL AX TREE\n\(tree)\n\nON-SCREEN WINDOWS\n\(windowReport(dockPID: dockPID, windows: windows))\n\nPRIVATE API\n\(PrivateAPI.report)"
    }

    private static func dumpTree(
        _ element: AXUIElement,
        depth: Int,
        remaining: inout Int
    ) -> [String] {
        guard remaining > 0 else { return ["\(String(repeating: "  ", count: depth))… node limit reached"] }
        remaining -= 1

        let indent = String(repeating: "  ", count: depth)
        let role = Accessibility.string(kAXRoleAttribute, of: element) ?? "?"
        let identifier = Accessibility.string(kAXIdentifierAttribute, of: element)
        let title = Accessibility.string(kAXTitleAttribute, of: element)
        let description = Accessibility.string(kAXDescriptionAttribute, of: element)
        let frame = Accessibility.frame(of: element)
        let childElements = Accessibility.children(of: element)
        var details = [role]
        if let identifier, !identifier.isEmpty { details.append("id=\(identifier)") }
        if let title, !title.isEmpty { details.append("title=\(title.debugDescription)") }
        if let description, !description.isEmpty { details.append("description=\(description.debugDescription)") }
        if let frame {
            details.append(String(
                format: "frame=(%.0f, %.0f, %.0f, %.0f)",
                frame.origin.x, frame.origin.y, frame.width, frame.height))
        }
        details.append("children=\(childElements.count)")

        var lines = [indent + details.joined(separator: "  ")]
        guard depth < 8 else { return lines }
        for child in childElements.prefix(50) {
            lines.append(contentsOf: dumpTree(child, depth: depth + 1, remaining: &remaining))
        }
        if childElements.count > 50 {
            lines.append("\(indent)  … \(childElements.count - 50) children omitted")
        }
        return lines
    }

    private static func windowReport(dockPID: pid_t, windows: [WindowInfo]) -> String {
        windows
            .filter { $0.layer == 0 || $0.pid == dockPID }
            .map { window in
                String(
                    format: "layer=%d pid=%d owner=%@ title=%@ frame=(%.0f, %.0f, %.0f, %.0f) alpha=%.2f",
                    window.layer,
                    window.pid,
                    window.owner,
                    window.title.debugDescription,
                    window.frame.origin.x,
                    window.frame.origin.y,
                    window.frame.width,
                    window.frame.height,
                    window.alpha)
            }
            .joined(separator: "\n")
    }
}
