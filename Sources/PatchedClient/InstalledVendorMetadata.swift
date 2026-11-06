import Foundation

/// Untrusted installed vendor claims, never permission to fetch, verify, publish or install.
public struct LocalInstalledVendorMetadata: Sendable, Equatable {
    public let sparkleFeedURL: String?
    public let electronConfigBytes: Data?
    public let productJSONBytes: Data?
    public let sparkleDisposition: LocalInventoryMetadataDisposition
    public let electronDisposition: LocalInventoryMetadataDisposition
    public let productJSONDisposition: LocalInventoryMetadataDisposition
    public var authorityUnknown: Bool { true }
    public var installationAllowed: Bool { false }
    public var verificationAllowed: Bool { false }
    public var publicationAllowed: Bool { false }

    internal init(sparkleFeedURL: String?, electronConfigBytes: Data?,
                  sparkleDisposition: LocalInventoryMetadataDisposition,
                  electronDisposition: LocalInventoryMetadataDisposition,
                  productJSONBytes: Data? = nil,
                  productJSONDisposition: LocalInventoryMetadataDisposition = .unavailable) {
        self.sparkleFeedURL = sparkleFeedURL
        self.electronConfigBytes = electronConfigBytes
        self.sparkleDisposition = sparkleDisposition
        self.electronDisposition = electronDisposition
        self.productJSONBytes = productJSONBytes
        self.productJSONDisposition = productJSONDisposition
    }

    // Namespace invalidation and unavailable scans retain no vendor claims.
    internal static var unavailable: Self {
        Self(sparkleFeedURL: nil, electronConfigBytes: nil,
             sparkleDisposition: .unavailable, electronDisposition: .unavailable)
    }
}
