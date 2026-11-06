import Foundation
import CryptoKit

/// Sparkle EdDSA (ed25519) signature over the archive bytes.
public enum SparkleSignature {
    /// - Parameters:
    ///   - publicKey: the installed app's `SUPublicEDKey`, or nil when it has none.
    ///   - signature: the offer's `sparkle:edSignature`.
    /// If the app pins a key, the offer must carry a signature and it must verify. A malformed key is a refusal.
    public static func check(publicKey: String?, signature: String?, archivePath: String) throws {
        guard let publicKey else { return }
        guard let keyBytes = Data(base64Encoded: publicKey.trimmingCharacters(in: .whitespacesAndNewlines)), keyBytes.count == 32,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes) else {
            throw InstallRefusal.edSignatureInvalid("the installed app's SUPublicEDKey is malformed")
        }
        guard let signature, !signature.isEmpty else { throw InstallRefusal.edSignatureMissing }
        guard let signatureBytes = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)),
              signatureBytes.count == 64 else {
            throw InstallRefusal.edSignatureInvalid("signature is not 64 base64-encoded bytes")
        }
        let archive: Data
        do { archive = try Data(contentsOf: URL(fileURLWithPath: archivePath), options: [.alwaysMapped]) }
        catch { throw InstallRefusal.io("cannot read the download for signature checking") }
        guard key.isValidSignature(signatureBytes, for: archive) else {
            throw InstallRefusal.edSignatureInvalid("signature does not match the download")
        }
    }
}
