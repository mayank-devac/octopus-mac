import CryptoKit
import Foundation

// Verify using the app's public key, not a second lookup of the signing key.
guard CommandLine.arguments.count == 4,
      let publicKey = Data(base64Encoded: CommandLine.arguments[2]),
      let signature = Data(base64Encoded: CommandLine.arguments[3]) else {
    fputs("Usage: verify-update.swift ARCHIVE PUBLIC_KEY SIGNATURE\n", stderr)
    exit(1)
}
do {
    let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
    guard key.isValidSignature(signature, for: archive) else {
        fputs("Update signature does not match the app's public key.\n", stderr)
        exit(1)
    }
    print("Sparkle update signature verified.")
} catch {
    fputs("Unable to verify the update signature.\n", stderr)
    exit(1)
}
