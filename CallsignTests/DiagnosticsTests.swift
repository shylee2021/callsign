import Testing
@testable import Callsign

@MainActor
struct DiagnosticsTests {
    @Test func recordingIsOptInCancelsPendingWorkAndKeepsTheLastReport() async throws {
        let probe = MissionControlProbe()
        let diagnostics = probe.diagnostics
        var captures = 0
        let capture: @MainActor () -> String = {
            captures += 1
            return "Report \(captures)"
        }
        #expect(!diagnostics.recordDiagnostics)
        #expect(diagnostics.scheduleReport(capture) == nil)
        #expect(captures == 0)

        diagnostics.recordDiagnostics = true
        let canceled = try #require(diagnostics.scheduleReport(capture))
        diagnostics.recordDiagnostics = false
        await canceled.value
        #expect(captures == 0)
        #expect(diagnostics.report.isEmpty)

        diagnostics.recordDiagnostics = true
        let completed = try #require(diagnostics.scheduleReport(capture))
        await completed.value
        #expect(captures == 1)
        #expect(diagnostics.report.hasSuffix("Report 1"))
        let duplicate = try #require(diagnostics.scheduleReport(capture))
        await duplicate.value
        #expect(captures == 1) // One capture per settled layout, not every poll.

        let savedReport = diagnostics.report
        diagnostics.recordDiagnostics = false
        #expect(diagnostics.report == savedReport) // Stop recording, then review/copy the last capture.
        #expect(diagnostics.scheduleReport(capture) == nil)
        diagnostics.recordDiagnostics = true
        let paused = try #require(diagnostics.scheduleReport(capture))
        probe.stop()
        await paused.value
        #expect(captures == 1)
        #expect(diagnostics.report == savedReport)
        #expect(!MissionControlProbe().diagnostics.recordDiagnostics) // A fresh session never inherits recording.
    }

    @Test func privateSymbolsResolveOnThisMacOS() {
        // A macOS update that drops a symbol should fail here, not silently degrade tags.
        #expect(PrivateAPI.axWindowID != nil)
        #expect(PrivateAPI.skyLight != nil)
        let report = PrivateAPI.report
        for symbol in [
            "_AXUIElementGetWindow", "CGSMainConnectionID", "SLSSpaceCreate", "SLSSpaceSetAbsoluteLevel",
            "SLSShowSpaces", "SLSSpaceAddWindowsAndRemoveFromSpaces", "SLSSpaceDestroy",
        ] {
            #expect(report.contains("\(symbol): resolved"))
        }
    }
}
