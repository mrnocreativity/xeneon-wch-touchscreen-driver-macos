import CoreGraphics
import Darwin
import Foundation

/// Lifetime of a persisted pairing.
public enum PairingScope: String, Codable, Equatable, Sendable {
    /// Legacy encoded name: runtime identifiers require uninterrupted process observation.
    case bootSession

    /// Both endpoints exposed public hardware identifiers that were unique when calibrated.
    case hardware
}

/// Persisted one-to-one association between a USB touch controller and a display.
public struct TouchDisplayPairing: Codable, Equatable, Sendable {
    static let currentCalibrationRevision = 3
    public let device: TouchDeviceIdentity
    public let displayID: CGDirectDisplayID
    public let displayVendorNumber: UInt32
    public let displayModelNumber: UInt32
    public let displaySerialNumber: UInt32
    public let bootSessionIdentifier: String
    public let scope: PairingScope
    public let observationSession: String?
    public let calibrationRevision: Int?

    public init(
        device: TouchDeviceIdentity,
        display: DisplaySnapshot,
        bootSessionIdentifier: String,
        scope: PairingScope,
        observationSession: String? = nil
    ) {
        self.device = device
        self.displayID = display.displayID
        self.displayVendorNumber = display.vendorNumber
        self.displayModelNumber = display.modelNumber
        self.displaySerialNumber = display.serialNumber
        self.bootSessionIdentifier = bootSessionIdentifier
        self.scope = scope
        self.observationSession = observationSession
        self.calibrationRevision = Self.currentCalibrationRevision
    }

    var displayHardwareKey: String? {
        guard displaySerialNumber != 0 else { return nil }
        return "edid:\(displayVendorNumber):\(displayModelNumber):\(displaySerialNumber)"
    }
}

private struct PairingFile: Codable {
    var version = 4
    var pairings: [TouchDisplayPairing]
}

private struct LegacyPairingFile: Decodable {
    let version: Int
}

/// Loads, validates, resolves, and atomically persists touch-display assignments.
public final class PairingStore {
    public private(set) var pairings: [TouchDisplayPairing]

    private let url: URL
    private let fileManager: FileManager
    private let bootSessionIdentifier: String
    private let observationSession: String

    public init(
        url: URL = PairingStore.defaultURL(),
        fileManager: FileManager = .default,
        bootSessionIdentifier: String = PairingStore.currentBootSessionIdentifier(),
        observationSession: String = UUID().uuidString
    ) {
        self.url = url
        self.fileManager = fileManager
        self.bootSessionIdentifier = bootSessionIdentifier
        self.observationSession = observationSession
        self.pairings = []
        load()
    }

    public static func defaultURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("MacXeneonEdgeTouchDriver", isDirectory: true)
            .appendingPathComponent("pairings.json", isDirectory: false)
    }

    /// A supported marker backed by the kernel-reported system boot time.
    public static func currentBootSessionIdentifier() -> String {
        currentBootSessionIdentifier(
            kernelBootTimeSeconds: kernelBootTimeSeconds(),
            now: Date(),
            systemUptime: ProcessInfo.processInfo.systemUptime
        )
    }

    static func currentBootSessionIdentifier(
        kernelBootTimeSeconds: Int64?,
        now: Date = Date(),
        systemUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> String {
        if let kernelBootTimeSeconds {
            return "boot-\(kernelBootTimeSeconds)"
        }

        let bootEpochSeconds = Int64((now.timeIntervalSince1970 - systemUptime).rounded())
        return "fallback-boot-\(bootEpochSeconds)"
    }

    /// Resolves a controller to a current display without using display bounds as identity.
    public func resolveDisplay(
        for device: TouchDeviceIdentity,
        connectedDevices: Set<TouchDeviceIdentity>,
        displays: [DisplaySnapshot]
    ) -> DisplaySnapshot? {
        guard connectedDevices.contains(device) else { return nil }
        if let exact = pairings.first(where: {
            $0.scope == .bootSession &&
            $0.observationSession == observationSession &&
            $0.calibrationRevision == TouchDisplayPairing.currentCalibrationRevision &&
            $0.bootSessionIdentifier == bootSessionIdentifier &&
            runtimeDevice($0.device, matches: device)
        }), let display = displays.first(where: {
            $0.displayID == exact.displayID && runtimeDisplay(exact, matches: $0)
        }) {
            return display
        }

        guard let deviceKey = device.hardwareKey,
              connectedDevices.filter({ $0.hardwareKey == deviceKey }).count == 1,
              pairings.filter({ $0.scope == .hardware && $0.device.hardwareKey == deviceKey }).count == 1,
              let pairing = pairings.first(where: {
                  $0.scope == .hardware && $0.device.hardwareKey == deviceKey
              }),
              let displayKey = pairing.displayHardwareKey,
              displays.filter({ $0.hardwareKey == displayKey }).count == 1,
              pairings.filter({ $0.scope == .hardware && $0.displayHardwareKey == displayKey }).count == 1 else {
            return nil
        }

        return displays.first { $0.hardwareKey == displayKey }
    }

    /// Removes same-boot pairings whose reused runtime identifiers now describe
    /// different public hardware. Missing endpoints are left for explicit removal
    /// callbacks so staged login enumeration cannot erase a valid pairing.
    @discardableResult
    public func reconcileRuntimeDescriptors(
        connectedDevices: Set<TouchDeviceIdentity>,
        displays: [DisplaySnapshot]
    ) throws -> Int {
        let originalCount = pairings.count
        pairings.removeAll { pairing in
            guard pairing.scope == .bootSession,
                  pairing.bootSessionIdentifier == bootSessionIdentifier else {
                return false
            }

            let deviceWasReused = connectedDevices
                .first { $0.locationID == pairing.device.locationID }
                .map { !runtimeDevice(pairing.device, matches: $0) } ?? false
            let displayWasReused = displays
                .first { $0.displayID == pairing.displayID }
                .map { !runtimeDisplay(pairing, matches: $0) } ?? false
            return deviceWasReused || displayWasReused
        }
        let removedCount = originalCount - pairings.count
        if removedCount > 0 { try save() }
        return removedCount
    }

    /// Invalidates ambiguous same-boot authority after a controller disconnects.
    public func invalidateBootSessionPairing(for device: TouchDeviceIdentity) throws {
        try removeBootSessionPairings {
            $0.device.locationID == device.locationID
        }
    }

    /// Invalidates ambiguous same-boot authority after display membership changes.
    public func invalidateBootSessionPairing(forDisplayID displayID: CGDirectDisplayID) throws {
        try removeBootSessionPairings { $0.displayID == displayID }
    }

    /// Assigns a mapping and chooses the strongest scope justified by current public data.
    public func assign(
        device: TouchDeviceIdentity,
        to display: DisplaySnapshot,
        connectedDevices: Set<TouchDeviceIdentity>,
        displays: [DisplaySnapshot]
    ) throws {
        guard connectedDevices.contains(device), displays.contains(display) else {
            throw PairingStoreError.missingEndpoint
        }
        let deviceKey = device.hardwareKey
        let displayKey = display.hardwareKey
        let hardwareIsUnique = deviceKey != nil &&
            displayKey != nil &&
            connectedDevices.filter { $0.hardwareKey == deviceKey }.count == 1 &&
            displays.filter { $0.hardwareKey == displayKey }.count == 1
        let scope: PairingScope = hardwareIsUnique ? .hardware : .bootSession

        var updated = pairings
        updated.removeAll { pairing in
            let sameRuntimeDevice = pairing.bootSessionIdentifier == bootSessionIdentifier &&
                pairing.device.locationID == device.locationID
            let sameRuntimeDisplay = pairing.bootSessionIdentifier == bootSessionIdentifier &&
                pairing.displayID == display.displayID
            let sameHardwareDevice = deviceKey != nil && pairing.scope == .hardware &&
                pairing.device.hardwareKey == deviceKey
            let sameHardwareDisplay = displayKey != nil && pairing.scope == .hardware &&
                pairing.displayHardwareKey == displayKey
            return sameRuntimeDevice || sameRuntimeDisplay || sameHardwareDevice || sameHardwareDisplay
        }

        updated.append(TouchDisplayPairing(
            device: device,
            display: display,
            bootSessionIdentifier: bootSessionIdentifier,
            scope: scope,
            observationSession: observationSession
        ))
        updated.sort {
            if $0.bootSessionIdentifier != $1.bootSessionIdentifier {
                return $0.bootSessionIdentifier < $1.bootSessionIdentifier
            }
            return $0.device.locationID < $1.device.locationID
        }
        try save(updated)
        pairings = updated
    }

    /// Revocation is immediate even if persistence fails. Old records cannot regain
    /// same-process authority while this store is alive.
    public func invalidateAmbiguous() throws {
        pairings.removeAll { $0.scope == .bootSession }
        try save()
    }

    public func invalidateAll() throws {
        pairings.removeAll()
        try save()
    }

    public func remove(device: TouchDeviceIdentity) throws {
        pairings.removeAll {
            $0.bootSessionIdentifier == bootSessionIdentifier &&
            $0.device.locationID == device.locationID
        }
        try save()
    }

    private func removeBootSessionPairings(
        where shouldRemove: (TouchDisplayPairing) -> Bool
    ) throws {
        let originalCount = pairings.count
        pairings.removeAll {
            $0.scope == .bootSession &&
            $0.bootSessionIdentifier == bootSessionIdentifier &&
            shouldRemove($0)
        }
        if pairings.count != originalCount { try save() }
    }

    private func runtimeDevice(
        _ saved: TouchDeviceIdentity,
        matches current: TouchDeviceIdentity
    ) -> Bool {
        guard saved.locationID == current.locationID,
              saved.serialNumber == current.serialNumber else {
            return false
        }
        return saved.registryEntryID == current.registryEntryID
    }

    private func runtimeDisplay(
        _ pairing: TouchDisplayPairing,
        matches display: DisplaySnapshot
    ) -> Bool {
        pairing.displayID == display.displayID &&
        pairing.displayVendorNumber == display.vendorNumber &&
        pairing.displayModelNumber == display.modelNumber &&
        pairing.displaySerialNumber == display.serialNumber
    }

    private func load() {
        guard fileManager.fileExists(atPath: url.path) else { return }

        do {
            let data = try Data(contentsOf: url)
            if let legacy = try? JSONDecoder().decode(LegacyPairingFile.self, from: data),
               legacy.version < 2 {
                DriverLoggers.log(.notice, category: .display, "Ignoring version-one runtime pairings; calibration will create supported current identities.")
                pairings = []
                return
            }
            let decoded = try JSONDecoder().decode(PairingFile.self, from: data)
            guard decoded.version == 4 else {
                pairings = []
                DriverLoggers.log(.notice, category: .display, "Saved pairings require the current physical calibration flow.")
                return
            }
            let bootCompatiblePairings = decoded.pairings.filter {
                $0.calibrationRevision == TouchDisplayPairing.currentCalibrationRevision &&
                ($0.scope == .hardware || $0.observationSession == observationSession)
            }
            let retainedPairings = bootCompatiblePairings.filter {
                $0.scope == .hardware || $0.bootSessionIdentifier == bootSessionIdentifier
            }
            // Reject every conflicting association, not just the first record.
            pairings = retainedPairings.filter { candidate in
                retainedPairings.filter {
                    $0.device.locationID == candidate.device.locationID ||
                    $0.displayID == candidate.displayID
                }.count == 1
            }
            if pairings.count != decoded.pairings.count {
                // Construction precedes command-endpoint ownership. Loading must
                // stay read-only so a rejected second daemon cannot mutate the
                // running owner's file. The next canonical save prunes disk data.
                DriverLoggers.log(.notice, category: .display,
                                 "Rejected expired or conflicting saved pairing authority.")
            }
        } catch {
            DriverLoggers.log(.error, category: .display, "Could not load pairing file at \(url.path): \(error.localizedDescription)")
            pairings = []
        }
    }

    private func save() throws {
        try save(pairings)
    }

    private func save(_ records: [TouchDisplayPairing]) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(PairingFile(pairings: records))
        try data.write(to: url, options: .atomic)
    }

    private static func kernelBootTimeSeconds() -> Int64? {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        let result = sysctlbyname("kern.boottime", &bootTime, &size, nil, 0)
        guard result == 0, size == MemoryLayout<timeval>.size else { return nil }
        return Int64(bootTime.tv_sec)
    }
}

enum PairingStoreError: Error {
    case missingEndpoint
}
