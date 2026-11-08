import Foundation
import IOKit.hid

/// Reads the HID descriptor without opening or seizing the touch interface.
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
        guard let size = IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int,
              size >= XeneonEdgeDevice.touchReportLength,
              let elements = IOHIDDeviceCopyMatchingElements(device, nil, 0) as? [IOHIDElement] else { return false }
        let report = elements.filter {
            Int(IOHIDElementGetReportID($0)) == XeneonEdgeDevice.touchReportID &&
                !IOHIDElementIsRelative($0) && IOHIDElementGetLogicalMin($0) == 0
        }
        let axes = report.filter {
            IOHIDElementGetType($0) == kIOHIDElementTypeInput_Misc &&
                IOHIDElementGetUsagePage($0) == kHIDPage_GenericDesktop && IOHIDElementGetReportSize($0) == 16
        }
        let hasContact = report.contains {
            IOHIDElementGetType($0) == kIOHIDElementTypeInput_Button &&
                IOHIDElementGetUsagePage($0) == kHIDPage_Button && IOHIDElementGetUsage($0) == 1 &&
                IOHIDElementGetReportSize($0) == 1 && IOHIDElementGetLogicalMax($0) == 1
        }
        return hasContact && axes.contains {
            IOHIDElementGetUsage($0) == kHIDUsage_GD_X &&
                IOHIDElementGetLogicalMax($0) == XeneonEdgeDevice.rawXRange.upperBound
        } && axes.contains {
            IOHIDElementGetUsage($0) == kHIDUsage_GD_Y &&
                IOHIDElementGetLogicalMax($0) == XeneonEdgeDevice.rawYRange.upperBound
        }
    }
}
