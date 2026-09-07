import CoreGraphics
import Foundation
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class PairingStoreTests: XCTestCase {
    func testFailedAssignmentDoesNotPublishInMemoryAuthority() throws {
        let url = temporaryURL()
        // A directory in place of the data file forces atomic persistence to fail.
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = PairingStore(url: url)
        let device = TouchDeviceIdentity(locationID: 1)
        let display = makeDisplay(id: 41, serial: 0)
        XCTAssertThrowsError(try store.assign(device: device, to: display,
                                              connectedDevices: [device], displays: [display]))
        XCTAssertTrue(store.pairings.isEmpty)
        XCTAssertNil(store.resolveDisplay(for: device, connectedDevices: [device], displays: [display]))
    }

    func testGroupRevocationPreservesOnlyUniqueHardwareAssociations() throws {
        let store = PairingStore(url: temporaryURL())
        let devices: Set = [TouchDeviceIdentity(locationID: 1), TouchDeviceIdentity(locationID: 2),
                            TouchDeviceIdentity(locationID: 3, serialNumber: "UNIQUE")]
        let displays = [makeDisplay(id: 41, serial: 0), makeDisplay(id: 42, serial: 0), makeDisplay(id: 43, serial: 99)]
        for (device, display) in zip(devices.sorted { $0.locationID < $1.locationID }, displays) {
            try store.assign(device: device, to: display, connectedDevices: devices, displays: displays)
        }
        try store.invalidateAmbiguous()
        XCTAssertEqual(store.pairings.count, 1)
        XCTAssertEqual(store.pairings.first?.scope, .hardware)
        try store.invalidateAll()
        XCTAssertTrue(store.pairings.isEmpty)
    }

    func testVersionThreeCannotRestoreEvenMatchingHIDRegistryEntry() throws {
        let url = temporaryURL()
        let device = TouchDeviceIdentity(locationID: 1, registryEntryID: 101)
        let display = makeDisplay(id: 41, serial: 0)
        let store = PairingStore(url: url, observationSession: "SAME")
        try store.assign(device: device, to: display, connectedDevices: [device], displays: [display])
        var data = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        data["version"] = 3
        try JSONSerialization.data(withJSONObject: data).write(to: url)
        let reloaded = PairingStore(url: url, observationSession: "SAME")
        XCTAssertTrue(reloaded.pairings.isEmpty)
    }

    func testMissingEndpointCannotBeAssigned() {
        let store = PairingStore(url: temporaryURL())
        XCTAssertThrowsError(try store.assign(device: TouchDeviceIdentity(locationID: 1),
                                              to: makeDisplay(id: 41, serial: 0), connectedDevices: [], displays: []))
        XCTAssertTrue(store.pairings.isEmpty)
    }

    func testAmbiguousAssignmentRequiresCalibrationAfterProcessRestartInSameBoot() throws {
        let url = temporaryURL()
        let device = TouchDeviceIdentity(locationID: 1, registryEntryID: 101)
        let display = makeDisplay(id: 41, serial: 0)
        let first = PairingStore(url: url, bootSessionIdentifier: "BOOT-A")

        try first.assign(
            device: device,
            to: display,
            connectedDevices: [device],
            displays: [display]
        )
        let reloaded = PairingStore(url: url, bootSessionIdentifier: "BOOT-A")

        XCTAssertNil(reloaded.resolveDisplay(for: device, connectedDevices: [device], displays: [display]))
        XCTAssertTrue(reloaded.pairings.isEmpty)
    }

    func testSameBootDisplayIDReuseByDifferentHardwareIsRejectedAndPruned() throws {
        let store = PairingStore(url: temporaryURL(), bootSessionIdentifier: "BOOT-A")
        let device = TouchDeviceIdentity(locationID: 1)
        let originalDisplay = makeDisplay(id: 41, serial: 0)
        try store.assign(
            device: device,
            to: originalDisplay,
            connectedDevices: [device],
            displays: [originalDisplay]
        )
        let reusedDisplay = makeDisplay(
            id: 41,
            serial: 0,
            vendor: 9_999,
            model: 8_888
        )

        XCTAssertNil(store.resolveDisplay(
            for: device,
            connectedDevices: [device],
            displays: [reusedDisplay]
        ))
        XCTAssertEqual(
            try store.reconcileRuntimeDescriptors(
                connectedDevices: [device],
                displays: [reusedDisplay]
            ),
            1
        )
        XCTAssertTrue(store.pairings.isEmpty)
    }

    func testSameBootControllerLocationReuseByDifferentSerialIsRejectedAndPruned() throws {
        let store = PairingStore(url: temporaryURL(), bootSessionIdentifier: "BOOT-A")
        let originalDevice = TouchDeviceIdentity(locationID: 1, serialNumber: "TOUCH-A")
        let display = makeDisplay(id: 41, serial: 0)
        try store.assign(
            device: originalDevice,
            to: display,
            connectedDevices: [originalDevice],
            displays: [display]
        )
        let reusedLocation = TouchDeviceIdentity(locationID: 1, serialNumber: "TOUCH-B")

        XCTAssertNil(store.resolveDisplay(
            for: reusedLocation,
            connectedDevices: [reusedLocation],
            displays: [display]
        ))
        XCTAssertEqual(
            try store.reconcileRuntimeDescriptors(
                connectedDevices: [reusedLocation],
                displays: [display]
            ),
            1
        )
        XCTAssertTrue(store.pairings.isEmpty)
    }

    func testSameBootControllerRegistryEntryReuseIsRejectedAndPruned() throws {
        let store = PairingStore(url: temporaryURL(), bootSessionIdentifier: "BOOT-A")
        let originalDevice = TouchDeviceIdentity(
            locationID: 1,
            serialNumber: "DUPLICATE",
            registryEntryID: 101
        )
        let display = makeDisplay(id: 41, serial: 0)
        try store.assign(
            device: originalDevice,
            to: display,
            connectedDevices: [originalDevice],
            displays: [display]
        )
        let reenumeratedDevice = TouchDeviceIdentity(
            locationID: 1,
            serialNumber: "DUPLICATE",
            registryEntryID: 202
        )

        XCTAssertNil(store.resolveDisplay(
            for: reenumeratedDevice,
            connectedDevices: [reenumeratedDevice],
            displays: [display]
        ))
        XCTAssertEqual(
            try store.reconcileRuntimeDescriptors(
                connectedDevices: [reenumeratedDevice],
                displays: [display]
            ),
            1
        )
        XCTAssertTrue(store.pairings.isEmpty)
    }

    func testDescriptorReconciliationKeepsTemporarilyMissingEndpoints() throws {
        let store = PairingStore(url: temporaryURL(), bootSessionIdentifier: "BOOT-A")
        let device = TouchDeviceIdentity(locationID: 1)
        let display = makeDisplay(id: 41, serial: 0)
        try store.assign(device: device, to: display, connectedDevices: [device], displays: [display])

        XCTAssertEqual(
            try store.reconcileRuntimeDescriptors(connectedDevices: [], displays: []),
            0
        )
        XCTAssertEqual(store.pairings.count, 1)
    }

    func testExplicitRemovalInvalidatesOnlyBootSessionAuthority() throws {
        let bootStore = PairingStore(url: temporaryURL(), bootSessionIdentifier: "BOOT-A")
        let ambiguousDevice = TouchDeviceIdentity(locationID: 1)
        let ambiguousDisplay = makeDisplay(id: 41, serial: 0)
        try bootStore.assign(
            device: ambiguousDevice,
            to: ambiguousDisplay,
            connectedDevices: [ambiguousDevice],
            displays: [ambiguousDisplay]
        )

        try bootStore.invalidateBootSessionPairing(forDisplayID: ambiguousDisplay.displayID)
        XCTAssertTrue(bootStore.pairings.isEmpty)

        let hardwareStore = PairingStore(url: temporaryURL(), bootSessionIdentifier: "BOOT-A")
        let identifiedDevice = TouchDeviceIdentity(locationID: 2, serialNumber: "TOUCH-A")
        let identifiedDisplay = makeDisplay(id: 42, serial: 101)
        try hardwareStore.assign(
            device: identifiedDevice,
            to: identifiedDisplay,
            connectedDevices: [identifiedDevice],
            displays: [identifiedDisplay]
        )

        try hardwareStore.invalidateBootSessionPairing(for: identifiedDevice)
        try hardwareStore.invalidateBootSessionPairing(forDisplayID: identifiedDisplay.displayID)
        XCTAssertEqual(hardwareStore.pairings.first?.scope, .hardware)
    }

    func testAmbiguousRuntimeAssignmentIsNotTrustedAfterBootChanges() throws {
        let url = temporaryURL()
        let oldDevice = TouchDeviceIdentity(locationID: 1, serialNumber: "DUPLICATE")
        let oldDisplay = makeDisplay(id: 41, serial: 0)
        let first = PairingStore(url: url, bootSessionIdentifier: "BOOT-A")
        try first.assign(
            device: oldDevice,
            to: oldDisplay,
            connectedDevices: [oldDevice],
            displays: [oldDisplay]
        )

        let newDevice = TouchDeviceIdentity(locationID: 2, serialNumber: "DUPLICATE")
        let newDisplay = makeDisplay(id: 51, serial: 0)
        let reloaded = PairingStore(url: url, bootSessionIdentifier: "BOOT-B")

        XCTAssertNil(reloaded.resolveDisplay(
            for: newDevice,
            connectedDevices: [newDevice],
            displays: [newDisplay]
        ))
        XCTAssertTrue(reloaded.pairings.isEmpty)
    }

    func testExpiredAuthorityIsRejectedWithoutMutatingSavedEvidenceAtLoad() throws {
        let url = temporaryURL()
        let device = TouchDeviceIdentity(locationID: 1)
        let display = makeDisplay(id: 41, serial: 0)
        let firstBoot = PairingStore(url: url, bootSessionIdentifier: "BOOT-A")
        try firstBoot.assign(device: device, to: display, connectedDevices: [device], displays: [display])
        let savedData = try Data(contentsOf: url)

        let secondBoot = PairingStore(url: url, bootSessionIdentifier: "BOOT-B")
        XCTAssertTrue(secondBoot.pairings.isEmpty)

        let oldBootReloaded = PairingStore(url: url, bootSessionIdentifier: "BOOT-A")
        XCTAssertTrue(oldBootReloaded.pairings.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), savedData)
    }

    func testUniquePublicHardwareIdentitiesRestoreAcrossBootAndRuntimeIDChanges() throws {
        let url = temporaryURL()
        let oldDevice = TouchDeviceIdentity(locationID: 1, serialNumber: "TOUCH-A")
        let oldDisplay = makeDisplay(id: 41, serial: 101)
        let first = PairingStore(url: url, bootSessionIdentifier: "BOOT-A")
        try first.assign(
            device: oldDevice,
            to: oldDisplay,
            connectedDevices: [oldDevice],
            displays: [oldDisplay]
        )

        let newDevice = TouchDeviceIdentity(locationID: 2, serialNumber: "TOUCH-A")
        let newDisplay = makeDisplay(id: 51, serial: 101, x: 2_000)
        let reloaded = PairingStore(url: url, bootSessionIdentifier: "BOOT-B")

        XCTAssertEqual(reloaded.pairings.first?.scope, .hardware)
        XCTAssertEqual(
            reloaded.resolveDisplay(for: newDevice, connectedDevices: [newDevice], displays: [newDisplay]),
            newDisplay
        )
    }

    func testDuplicateControllerSerialPreventsCrossBootResolution() throws {
        let url = temporaryURL()
        let firstDevice = TouchDeviceIdentity(locationID: 1, serialNumber: "SAME")
        let secondDevice = TouchDeviceIdentity(locationID: 2, serialNumber: "SAME")
        let firstDisplay = makeDisplay(id: 41, serial: 101)
        let secondDisplay = makeDisplay(id: 42, serial: 102)
        let devices: Set = [firstDevice, secondDevice]
        let displays = [firstDisplay, secondDisplay]
        let first = PairingStore(url: url, bootSessionIdentifier: "BOOT-A")
        try first.assign(device: firstDevice, to: firstDisplay, connectedDevices: devices, displays: displays)
        try first.assign(device: secondDevice, to: secondDisplay, connectedDevices: devices, displays: displays)

        let reloaded = PairingStore(url: url, bootSessionIdentifier: "BOOT-B")
        let currentDevices: Set = [
            TouchDeviceIdentity(locationID: 11, serialNumber: "SAME"),
            TouchDeviceIdentity(locationID: 12, serialNumber: "SAME")
        ]
        let currentDisplays = [makeDisplay(id: 51, serial: 101), makeDisplay(id: 52, serial: 102)]

        XCTAssertTrue(reloaded.pairings.isEmpty)
        XCTAssertNil(reloaded.resolveDisplay(
            for: currentDevices.first!,
            connectedDevices: currentDevices,
            displays: currentDisplays
        ))
    }

    func testDuplicateDisplaySerialPreventsHardwareScope() throws {
        let store = PairingStore(url: temporaryURL(), bootSessionIdentifier: "BOOT-A")
        let device = TouchDeviceIdentity(locationID: 1, serialNumber: "TOUCH-A")
        let firstDisplay = makeDisplay(id: 41, serial: 101)
        let secondDisplay = makeDisplay(id: 42, serial: 101)

        try store.assign(
            device: device,
            to: firstDisplay,
            connectedDevices: [device],
            displays: [firstDisplay, secondDisplay]
        )

        XCTAssertEqual(store.pairings.first?.scope, .bootSession)
    }

    func testAssignmentMaintainsOneToOneRuntimeMapping() throws {
        let store = PairingStore(url: temporaryURL(), bootSessionIdentifier: "BOOT-A")
        let first = TouchDeviceIdentity(locationID: 1)
        let second = TouchDeviceIdentity(locationID: 2)
        let display = makeDisplay(id: 41, serial: 0)
        let devices: Set = [first, second]
        try store.assign(device: first, to: display, connectedDevices: devices, displays: [display])

        try store.assign(device: second, to: display, connectedDevices: devices, displays: [display])

        XCTAssertNil(store.resolveDisplay(for: first, connectedDevices: devices, displays: [display]))
        XCTAssertEqual(
            store.resolveDisplay(for: second, connectedDevices: devices, displays: [display]),
            display
        )
    }

    func testVersionOnePairingsAreIgnoredSafely() throws {
        let url = temporaryURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let legacy = Data(#"{"version":1,"pairings":[{"device":{"locationID":1},"displayUUID":"OLD"}]}"#.utf8)
        try legacy.write(to: url, options: .atomic)

        let store = PairingStore(url: url, bootSessionIdentifier: "BOOT-B")

        XCTAssertTrue(store.pairings.isEmpty)
    }

    func testVersionTwoBootSessionPairingsAreDiscarded() throws {
        let url = temporaryURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let legacy = Data(#"{"version":2,"pairings":[{"device":{"locationID":1,"serialNumber":"DUPLICATE"},"displayID":41,"displayVendorNumber":7745,"displayModelNumber":21579,"displaySerialNumber":0,"bootSessionIdentifier":"BOOT-A","scope":"bootSession"}]}"#.utf8)
        try legacy.write(to: url, options: .atomic)

        let store = PairingStore(url: url, bootSessionIdentifier: "BOOT-A")

        XCTAssertTrue(store.pairings.isEmpty)
        let persisted = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        // Preserve the old file for diagnosis until canonical calibration/reset saves v4.
        XCTAssertEqual(persisted?["version"] as? Int, 2)
    }

    func testOldHardwarePairingRequiresNewCalibrationProtocol() throws {
        let url = temporaryURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let legacy = Data(#"{"version":2,"pairings":[{"device":{"locationID":1,"serialNumber":"TOUCH-A"},"displayID":41,"displayVendorNumber":3672,"displayModelNumber":60672,"displaySerialNumber":101,"bootSessionIdentifier":"BOOT-A","scope":"hardware"}]}"#.utf8)
        try legacy.write(to: url, options: .atomic)
        let currentDevice = TouchDeviceIdentity(
            locationID: 2,
            serialNumber: "TOUCH-A",
            registryEntryID: 202
        )
        let currentDisplay = makeDisplay(id: 51, serial: 101)

        let store = PairingStore(url: url, bootSessionIdentifier: "BOOT-B")

        XCTAssertTrue(store.pairings.isEmpty)
        XCTAssertNil(
            store.resolveDisplay(
                for: currentDevice,
                connectedDevices: [currentDevice],
                displays: [currentDisplay]
            )
        )
    }

    func testBootSessionIdentifierUsesKernelBootTimeAcrossProcessTimes() {
        let now = Date(timeIntervalSince1970: 10_000)

        XCTAssertEqual(
            PairingStore.currentBootSessionIdentifier(
                kernelBootTimeSeconds: 8_765,
                now: now,
                systemUptime: 1_000
            ),
            "boot-8765"
        )
        XCTAssertEqual(
            PairingStore.currentBootSessionIdentifier(
                kernelBootTimeSeconds: 8_765,
                now: now.addingTimeInterval(20),
                systemUptime: 1_020
            ),
            "boot-8765"
        )
    }

    func testBootSessionIdentifierFallbackCannotMatchKernelMarker() {
        XCTAssertEqual(
            PairingStore.currentBootSessionIdentifier(
                kernelBootTimeSeconds: nil,
                now: Date(timeIntervalSince1970: 10_000),
                systemUptime: 1_000
            ),
            "fallback-boot-9000"
        )
    }

    private func makeDisplay(
        id: CGDirectDisplayID,
        serial: UInt32,
        x: CGFloat = 0,
        vendor: UInt32 = CapturedXeneonDisplay.vendorNumber,
        model: UInt32 = CapturedXeneonDisplay.modelNumber
    ) -> DisplaySnapshot {
        DisplaySnapshot(
            displayID: id,
            runtimeIdentifier: "display-\(id)",
            vendorNumber: vendor,
            modelNumber: model,
            serialNumber: serial,
            bounds: CGRect(x: x, y: 200, width: 1_280, height: 480),
            pixelsWide: 1_280,
            pixelsHigh: 480
        )
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MacXeneonEdgeTouchDriverTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("pairings.json")
    }
}
