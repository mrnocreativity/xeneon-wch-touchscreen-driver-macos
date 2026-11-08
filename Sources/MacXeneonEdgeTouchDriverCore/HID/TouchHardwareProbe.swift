import Foundation
import IOKit
import IOKit.hid

/// Checks the HID report metadata without accessing live input.
public enum TouchHardwareProbe: Int32 {
    case supported = 0
    case noController = 3
    case unverifiedReportFormat = 4

    static let deviceMatching: [String: Any] = [
        kIOHIDVendorIDKey as String: XeneonEdgeDevice.vendorID,
        kIOHIDProductIDKey as String: XeneonEdgeDevice.productID,
        kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
        kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Mouse
    ]

    public static func detect() -> Self {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, deviceMatching as CFDictionary)
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              !devices.isEmpty else { return .noController }
        return devices.contains(where: hasSupportedDescriptor) ? .supported : .unverifiedReportFormat
    }

    private static func hasSupportedDescriptor(_ device: IOHIDDevice) -> Bool {
        // Reading a single registry property omits the child elements of
        // collections. Read the complete property table for the element tree.
        var table: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(IOHIDDeviceGetService(device), &table, kCFAllocatorDefault, 0)
        guard result == KERN_SUCCESS, let properties = table?.takeRetainedValue() as? [String: Any],
              let size = properties[kIOHIDMaxInputReportSizeKey] as? Int,
              size >= XeneonEdgeDevice.touchReportLength,
              let elements = properties[kIOHIDElementKey] as? [[String: Any]] else { return false }
        return hasSupportedElements(elements)
    }

    // CopyMatchingElements opens a protected HID user client. The registry
    // contains the descriptor's element tree even before Input Monitoring.
    static func hasSupportedElements(_ elements: [[String: Any]]) -> Bool {
        let report = flatten(elements).filter {
            $0[kIOHIDElementReportIDKey] as? Int == XeneonEdgeDevice.touchReportID &&
                $0[kIOHIDElementIsRelativeKey] as? Bool == false && $0[kIOHIDElementMinKey] as? Int == 0
        }
        let axes = report.filter {
            $0[kIOHIDElementTypeKey] as? Int == Int(kIOHIDElementTypeInput_Misc.rawValue) &&
                $0[kIOHIDElementUsagePageKey] as? Int == kHIDPage_GenericDesktop &&
                $0[kIOHIDElementReportSizeKey] as? Int == 16
        }
        let hasContact = report.contains {
            $0[kIOHIDElementTypeKey] as? Int == Int(kIOHIDElementTypeInput_Button.rawValue) &&
                $0[kIOHIDElementUsagePageKey] as? Int == kHIDPage_Button && $0[kIOHIDElementUsageKey] as? Int == 1 &&
                $0[kIOHIDElementReportSizeKey] as? Int == 1 && $0[kIOHIDElementMaxKey] as? Int == 1
        }
        return hasContact && axes.contains {
            $0[kIOHIDElementUsageKey] as? Int == kHIDUsage_GD_X &&
                $0[kIOHIDElementMaxKey] as? Int == XeneonEdgeDevice.rawXRange.upperBound
        } && axes.contains {
            $0[kIOHIDElementUsageKey] as? Int == kHIDUsage_GD_Y &&
                $0[kIOHIDElementMaxKey] as? Int == XeneonEdgeDevice.rawYRange.upperBound
        }
    }

    private static func flatten(_ elements: [[String: Any]]) -> [[String: Any]] {
        elements.flatMap { element in
            [element] + flatten(element[kIOHIDElementKey] as? [[String: Any]] ?? [])
        }
    }
}
