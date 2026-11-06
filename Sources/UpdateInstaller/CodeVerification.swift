import Foundation
import Security

/// The signature and Gatekeeper checks, behind a protocol so pipeline tests can use a fake. The real
/// implementation is tested separately against real installed apps.
public protocol CodeVerifying: Sendable {
    /// Strict, all-architecture, nested-code validation against
    /// `anchor apple generic and certificate leaf[subject.OU] = "<teamID>"`.
    func verifySignature(ofBundleAt path: String, teamID: String) throws
    /// Gatekeeper must accept the bundle for execution as notarised Developer ID software.
    func assessGatekeeper(ofBundleAt path: String) throws
}

public enum TeamIdentifier {
    /// Apple Team IDs are ten upper-case letters or digits. Anything else could inject into a requirement.
    public static func isValid(_ team: String) -> Bool {
        team.utf8.count == 10 && team.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
    }
    public static func requirement(for team: String) throws -> String {
        guard isValid(team) else { throw InstallRefusal.cannotPinIdentity("Team ID \"\(team)\" is not a valid Apple Team ID") }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }
}

public struct SystemCodeVerifier: CodeVerifying {
    /// `kSecCSEnforceRevocationChecks` (1 << 30) is an enum constant Swift does not import.
    static let enforceRevocationChecks: UInt32 = 1 << 30
    public let enforceRevocation: Bool

    public init(enforceRevocation: Bool = true) { self.enforceRevocation = enforceRevocation }

    public func verifySignature(ofBundleAt path: String, teamID: String) throws {
        let requirementText = try TeamIdentifier.requirement(for: teamID)
        var code: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code)
        guard created == errSecSuccess, let code else {
            throw InstallRefusal.signatureInvalid("cannot read the code signature (OSStatus \(created))")
        }
        var requirement: SecRequirement?
        let parsed = SecRequirementCreateWithString(requirementText as CFString, [], &requirement)
        guard parsed == errSecSuccess, let requirement else {
            throw InstallRefusal.signatureInvalid("cannot build the requirement (OSStatus \(parsed))")
        }
        var flags = kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode
        if enforceRevocation { flags |= Self.enforceRevocationChecks }
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, SecCSFlags(rawValue: flags), requirement, &error)
        guard status == errSecSuccess else {
            let detail = error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? ""
            let hint = status == errSecCSReqFailed ? "not signed by Team ID \(teamID)" : "OSStatus \(status)"
            throw InstallRefusal.signatureInvalid(hint + (detail.isEmpty ? "" : " (\(detail.prefix(200)))"))
        }
        // Belt and braces: the signing information must name the same team.
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              dictionary[kSecCodeInfoTeamIdentifier as String] as? String == teamID else {
            throw InstallRefusal.signatureInvalid("signing information does not name Team ID \(teamID)")
        }
    }

    /// `spctl --assess --type execute -vv <path>` (fixed argv). SecAssessment is not in the public SDK.
    /// Requires "accepted" and "source=Notarized Developer ID"; an assessment override (Gatekeeper
    /// disabled) is refused because it would mean nothing was assessed.
    public func assessGatekeeper(ofBundleAt path: String) throws {
        let result = ProcessRunner.run("/usr/sbin/spctl", ["--assess", "--type", "execute", "-vv", path], timeout: 120)
        let text = result.stdout + "\n" + result.stderr
        try Self.interpretAssessment(status: result.timedOut ? -1 : result.status, output: text, path: path)
    }

    public static func interpretAssessment(status: Int32, output: String, path: String) throws {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard status == 0, lines.contains("\(path): accepted") else {
            throw InstallRefusal.notarisationRejected(lines.first(where: { !$0.isEmpty }).map { String($0.prefix(200)) } ?? "exit \(status)")
        }
        if lines.contains(where: { $0.hasPrefix("override=") }) {
            throw InstallRefusal.notarisationRejected("Gatekeeper assessment is overridden or disabled")
        }
        guard lines.contains("source=Notarized Developer ID") else {
            throw InstallRefusal.notarisationRejected(lines.first(where: { $0.hasPrefix("source=") }) ?? "not notarised Developer ID")
        }
    }
}
