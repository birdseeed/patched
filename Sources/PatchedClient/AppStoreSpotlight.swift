import Foundation
import CoreServices
import UpdateSources

/// The App Store's own ID for an installed app, from Spotlight's `kMDItemAppStoreAdamID`. Read only, and only after a
/// click on Open in App Store for an app whose listing the public lookup did not give.
@_spi(Testing) public enum SpotlightAppStoreID {
    public static let attribute = "kMDItemAppStoreAdamID"

    public static func adamID(forPath path: String) -> Int? {
        if RealStateTripwire.isActive { return nil }
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString),
              let value = MDItemCopyAttribute(item, attribute as CFString) else { return nil }
        return positiveInteger(value)
    }

    /// A whole number above zero (and exactly representable); text, booleans, fractions, zero and negatives are not an ID.
    public static func positiveInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number as CFNumber) else { return nil }
        let int = number.int64Value
        guard int > 0, int <= 9_007_199_254_740_991, NSNumber(value: int) == number else { return nil }
        return Int(int)
    }
}
