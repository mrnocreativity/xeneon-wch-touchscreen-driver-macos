enum SupportedDisplayCatalog {
    struct Entry {
        let name: String
        let vendorNumber: UInt32
        let modelNumber: UInt32
        let preferredResolution: (width: Int, height: Int)?
    }

    static let xeneonEdgeResolution = (width: 2_560, height: 720)
    static let xeneonEdge = Entry(
        name: "Corsair Xeneon Edge",
        vendorNumber: 3_672,
        modelNumber: 60_672,
        preferredResolution: xeneonEdgeResolution
    )

    /// Add verified display identities here to enable built-in matching.
    static let entries = [
        xeneonEdge,
        Entry(
            name: "Prechen HD-123 (12.3FHD)",
            vendorNumber: 7_745,
            modelNumber: 21_579,
            preferredResolution: nil
        )
    ]
}

/// Display values captured with the `DisplayInfo` diagnostic on this machine.
public enum CapturedXeneonDisplay {
    /// Captured on 2026-05-02 with `swift run DisplayInfo`.
    public static let captureNote = "Captured on 2026-05-02 with swift run DisplayInfo."

    /// EDID vendor number reported for the Xeneon Edge.
    public static let vendorNumber = SupportedDisplayCatalog.xeneonEdge.vendorNumber

    /// EDID model number reported for the Xeneon Edge.
    public static let modelNumber = SupportedDisplayCatalog.xeneonEdge.modelNumber

    /// Serial number reported by the Xeneon Edge. Not unique in this setup.
    public static let observedSerialNumber: UInt32 = 16_843_009

    /// Expected physical pixel width for the Xeneon Edge.
    public static let expectedWidth = SupportedDisplayCatalog.xeneonEdgeResolution.width

    /// Expected physical pixel height for the Xeneon Edge.
    public static let expectedHeight = SupportedDisplayCatalog.xeneonEdgeResolution.height
}
