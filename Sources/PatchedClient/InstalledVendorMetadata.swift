import Foundation

/// Untrusted installed vendor claims, never permission to fetch, verify, publish or install.
public struct LocalInstalledVendorMetadata: Sendable, Equatable {
    public let sparkleFeedURL: String?
    public let electronConfigBytes: Data?
    public let productJSONBytes: Data?
    /// `SUPublicEDKey` as the installer reads it: nil when absent, the string when a string, "" for any other type.
    public let sparklePublicEDKey: String?
    /// `LSBackgroundOnly` truthy in Info.plist and no icon of its own named there (a helper, not an app people
    /// know they have). Display hint only, never authority.
    public let backgroundOnly: Bool
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
                  productJSONDisposition: LocalInventoryMetadataDisposition = .unavailable,
                  sparklePublicEDKey: String? = nil,
                  backgroundOnly: Bool = false) {
        self.sparkleFeedURL = sparkleFeedURL
        self.electronConfigBytes = electronConfigBytes
        self.sparkleDisposition = sparkleDisposition
        self.electronDisposition = electronDisposition
        self.productJSONBytes = productJSONBytes
        self.productJSONDisposition = productJSONDisposition
        self.sparklePublicEDKey = sparklePublicEDKey
        self.backgroundOnly = backgroundOnly
    }

    // Namespace invalidation and unavailable scans retain no vendor claims.
    internal static var unavailable: Self {
        Self(sparkleFeedURL: nil, electronConfigBytes: nil,
             sparkleDisposition: .unavailable, electronDisposition: .unavailable)
    }
}
