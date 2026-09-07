import Foundation
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class DriverControlTests: XCTestCase {
    func testCommandsRoundTripAndSecondOwnerCannotStealSocket() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = DriverControl(directory: directory)
        try server.start { command, reply in reply("ack:\(command)") }
        defer { server.stop() }
        XCTAssertEqual(try DriverControl.request("status", directory: directory), "ack:status")
        let other = DriverControl(directory: directory)
        XCTAssertThrowsError(try other.start { _, reply in reply("wrong owner") })
        other.stop()
        XCTAssertEqual(try DriverControl.request("re-pair", directory: directory), "ack:re-pair")
        server.stop()
        XCTAssertThrowsError(try DriverControl.request("status", directory: directory))
        try other.start { _, reply in reply("new owner") }
        defer { other.stop() }
        XCTAssertEqual(try DriverControl.request("status", directory: directory), "new owner")
    }

    func testUnexpectedFileAtSocketPathIsPreserved() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("control.sock")
        let content = Data("preserve me".utf8)
        try content.write(to: path)
        let server = DriverControl(directory: directory)
        XCTAssertThrowsError(try server.start { _, _ in })
        server.stop()
        XCTAssertEqual(try Data(contentsOf: path), content)
    }

    private func temporaryDirectory() -> URL {
        // Keep the test endpoint within Darwin's sockaddr_un path limit.
        URL(fileURLWithPath: "/tmp/xeneon-control-\(UUID().uuidString)", isDirectory: true)
    }
}
