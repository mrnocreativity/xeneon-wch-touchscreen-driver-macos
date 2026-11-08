import CoreGraphics
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class CompatibilityReporterTests: XCTestCase {
    func testInvitationIsRememberedPerModelAcrossReporterInstances() throws {
        let suite = "CompatibilityReporterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = display(id: 123, model: 600)
        let secondUnit = display(id: 456, model: 600)
        let differentModel = display(id: 789, model: 601)
        XCTAssertTrue(CompatibilityReporter(defaults: defaults)
            .claimPrompt(key: CompatibilityReporter.promptKey(for: first)))

        let restarted = CompatibilityReporter(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertFalse(restarted.claimPrompt(key: CompatibilityReporter.promptKey(for: secondUnit)))
        XCTAssertTrue(restarted.claimPrompt(key: CompatibilityReporter.promptKey(for: differentModel)))
    }

    func testReportIncludesModelMatchingFieldsWithoutUnitIdentifiers() {
        let report = CompatibilityReporter.report(for: display(id: 123_456, model: 600), name: "Example panel")
        XCTAssertTrue(report.contains("Example panel"))
        XCTAssertTrue(report.contains("Display vendor ID: 500"))
        XCTAssertTrue(report.contains("Display model ID: 600"))
        XCTAssertTrue(report.contains("1280 × 480"))
        XCTAssertTrue(report.contains("27C0:0859"))
        XCTAssertFalse(report.contains("123456"))
        XCTAssertFalse(report.contains("987654"))
    }

    private func display(id: CGDirectDisplayID, model: UInt32) -> DisplaySnapshot {
        DisplaySnapshot(displayID: id, vendorNumber: 500, modelNumber: model, serialNumber: 987_654,
            bounds: .zero, pixelsWide: 1280, pixelsHigh: 480)
    }
}
