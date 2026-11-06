import Foundation
import Security

public enum CodeSigningIdentity {
    /// The Team ID in the bundle's code signature, or nil for unsigned or ad-hoc bundles.
    /// This reads the signature; it does not validate it (Phase 2 validates before installing).
    public static func teamID(ofBundleAt url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any], let team = dict[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty else { return nil }
        return team
    }
}
