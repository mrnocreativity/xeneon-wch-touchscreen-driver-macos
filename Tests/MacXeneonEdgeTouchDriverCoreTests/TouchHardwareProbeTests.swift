import IOKit.hid
import XCTest
@testable import MacXeneonEdgeTouchDriverCore

final class TouchHardwareProbeTests: XCTestCase {
    func testReportMetadataMustContainContactAndBothAbsoluteAxes() {
        let contact = element(type: kIOHIDElementTypeInput_Button, page: kHIDPage_Button,
                              usage: 1, size: 1, max: 1)
        let x = element(type: kIOHIDElementTypeInput_Misc, page: kHIDPage_GenericDesktop,
                        usage: kHIDUsage_GD_X, size: 16, max: XeneonEdgeDevice.rawXRange.upperBound)
        let y = element(type: kIOHIDElementTypeInput_Misc, page: kHIDPage_GenericDesktop,
                        usage: kHIDUsage_GD_Y, size: 16, max: XeneonEdgeDevice.rawYRange.upperBound)
        let collection = [[kIOHIDElementKey: [[kIOHIDElementKey: [contact, x, y]]]]]
        XCTAssertTrue(TouchHardwareProbe.hasSupportedElements(collection))
        XCTAssertFalse(TouchHardwareProbe.hasSupportedElements([x, y]))
        XCTAssertFalse(TouchHardwareProbe.hasSupportedElements([contact, x]))

        var relativeY = y
        relativeY[kIOHIDElementIsRelativeKey] = true
        XCTAssertFalse(TouchHardwareProbe.hasSupportedElements([contact, x, relativeY]))

        var unrelatedContact = contact
        unrelatedContact[kIOHIDElementReportIDKey] = XeneonEdgeDevice.touchReportID + 1
        XCTAssertFalse(TouchHardwareProbe.hasSupportedElements([unrelatedContact, x, y]))
    }

    private func element(type: IOHIDElementType, page: Int, usage: Int, size: Int, max: Int) -> [String: Any] {
        [
            kIOHIDElementTypeKey: Int(type.rawValue),
            kIOHIDElementUsagePageKey: page,
            kIOHIDElementUsageKey: usage,
            kIOHIDElementReportSizeKey: size,
            kIOHIDElementMinKey: 0,
            kIOHIDElementMaxKey: max,
            kIOHIDElementIsRelativeKey: false,
            kIOHIDElementReportIDKey: XeneonEdgeDevice.touchReportID
        ]
    }
}
