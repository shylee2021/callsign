import Testing
@testable import Callsign

@MainActor
struct DiagnosticsTests {
    @Test func recordingIsOptInCancelsPendingWorkAndKeepsTheLastReport() async throws {
        let probe = MissionControlProbe()
        var captures = 0
        let capture: @MainActor () -> String = {
            captures += 1
            return "Report \(captures)"
        }
        #expect(!probe.recordDiagnostics)
        #expect(probe.scheduleReport(capture) == nil)
        #expect(captures == 0)

        probe.recordDiagnostics = true
        let canceled = try #require(probe.scheduleReport(capture))
        probe.recordDiagnostics = false
        await canceled.value
        #expect(captures == 0)
        #expect(probe.report.isEmpty)

        probe.recordDiagnostics = true
        let completed = try #require(probe.scheduleReport(capture))
        await completed.value
        #expect(captures == 1)
        #expect(probe.report.hasSuffix("Report 1"))
        let duplicate = try #require(probe.scheduleReport(capture))
        await duplicate.value
        #expect(captures == 1) // One capture per settled layout, not every poll.

        let savedReport = probe.report
        probe.recordDiagnostics = false
        #expect(probe.report == savedReport) // Stop recording, then review/copy the last capture.
        #expect(probe.scheduleReport(capture) == nil)
        probe.recordDiagnostics = true
        let paused = try #require(probe.scheduleReport(capture))
        probe.stop()
        await paused.value
        #expect(captures == 1)
        #expect(probe.report == savedReport)
        #expect(!MissionControlProbe().recordDiagnostics) // A fresh session never inherits recording.
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
