// Ed25519 release signing for Patched's own updates (Apple SDK only: CryptoKit).
//
//   release-signing sign <zip> <sig-out>         private key (base64, raw 32 bytes) on stdin
//   release-signing verify <zip> <sig> <pubkey>  exit 0 only if the signature verifies
//   release-signing public-key                   private key on stdin, its public key on stdout
//   release-signing generate-test-key            a new throwaway private key on stdout (checks only)
//
// The private key is only ever read from stdin and never printed, logged or written anywhere. The .sig
// file is the 64-byte signature in base64 on one line, which is what Patched's SelfUpdater reads.
import Foundation
import CryptoKit
import Darwin

func fail(_ message: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("release-signing: " + message + "\n").utf8))
    exit(code)
}

func readPrivateKey() -> Curve25519.Signing.PrivateKey {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard input.count <= 1024 else { fail("the key on stdin is too long") }
    let text = String(decoding: input, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { fail("no signing key on stdin") }
    guard let raw = Data(base64Encoded: text), raw.count == 32,
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("the signing key is not 32 base64-encoded bytes")
    }
    return key
}

func readArchive(_ path: String) -> Data {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: [.alwaysMapped]), !data.isEmpty else {
        fail("cannot read \(path)")
    }
    return data
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "sign"?:
    guard arguments.count == 3 else { fail("usage: sign <zip> <sig-out>", 2) }
    let key = readPrivateKey()
    let archive = readArchive(arguments[1])
    guard let signature = try? key.signature(for: archive) else { fail("signing failed") }
    let line = Data((signature.base64EncodedString() + "\n").utf8)
    let fd = open(arguments[2], O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
    guard fd >= 0 else { fail("cannot create \(arguments[2])") }
    let written = line.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
    guard written == line.count, fsync(fd) == 0, close(fd) == 0 else { fail("cannot write \(arguments[2])") }
case "verify"?:
    guard arguments.count == 4 else { fail("usage: verify <zip> <sig> <public-key-base64>", 2) }
    guard let keyBytes = Data(base64Encoded: arguments[3]), keyBytes.count == 32,
          let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes) else { fail("malformed public key") }
    guard let sigData = try? Data(contentsOf: URL(fileURLWithPath: arguments[2])), sigData.count <= 1024 else {
        fail("cannot read \(arguments[2])")
    }
    let text = String(decoding: sigData, as: UTF8.self)
    guard text.hasSuffix("\n"), !text.dropLast().contains(where: \.isWhitespace),
          let signature = Data(base64Encoded: String(text.dropLast())), signature.count == 64 else {
        fail("\(arguments[2]) is not one line holding a base64 64-byte signature")
    }
    guard publicKey.isValidSignature(signature, for: readArchive(arguments[1])) else {
        fail("the signature does not verify against public key \(arguments[3])")
    }
    print("release-signing: signature verifies against \(arguments[3])")
case "public-key"?:
    guard arguments.count == 1 else { fail("usage: public-key", 2) }
    print(readPrivateKey().publicKey.rawRepresentation.base64EncodedString())
case "generate-test-key"?:
    guard arguments.count == 1 else { fail("usage: generate-test-key", 2) }
    print(Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString())
default:
    fail("usage: release-signing sign|verify|public-key|generate-test-key", 2)
}
