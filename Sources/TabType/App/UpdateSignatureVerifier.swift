import Foundation
import Security
import CryptoKit

/// A certificate's display name is not its identity: anyone can create another
/// self-signed certificate called TabType Dev. Releases must retain the signing
/// certificate and code identifier of the installed copy.
enum UpdateSignatureVerifier {
    struct Identity: Equatable, Sendable {
        let identifier: String
        let certificate: Data
    }

    struct VerificationError: Error, CustomStringConvertible {
        let description: String
    }

    static func verifyUpdate(at candidate: URL, replacing installed: URL) throws {
        let expected = try identity(at: installed)
        let actual = try identity(at: candidate, requirement: requirement(for: expected))
        guard actual == expected else {
            throw VerificationError(description: "The update has a different signing certificate or app identifier")
        }
    }

    /// Apply the pin while checking *all* architectures, not just the native
    /// slice returned by CopySigningInformation in a universal app.
    static func requirement(for identity: Identity) throws -> SecRequirement {
        let identifier = identity.identifier.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        // Security's certificate equality requirement uses the certificate's
        // SHA-1 fingerprint. Also compare the native leaf's complete DER below.
        let fingerprint = Insecure.SHA1.hash(data: identity.certificate)
            .map { String(format: "%02x", $0) }.joined()
        let expression = "identifier \"\(identifier)\" and certificate leaf = H\"\(fingerprint)\""
        var requirement: SecRequirement?
        try check(SecRequirementCreateWithString(expression as CFString, [], &requirement))
        guard let requirement else { throw VerificationError(description: "Couldn't pin app signature") }
        return requirement
    }

    static func identity(at url: URL, requirement: SecRequirement? = nil) throws -> Identity {
        var code: SecStaticCode?
        try check(SecStaticCodeCreateWithPath(url as CFURL, [], &code))
        guard let code else { throw VerificationError(description: "Couldn't read app signature") }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures)
        try check(SecStaticCodeCheckValidity(code, flags, requirement))
        var information: CFDictionary?
        try check(SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information))
        guard let info = information as? [String: Any],
              let identifier = info[kSecCodeInfoIdentifier as String] as? String, !identifier.isEmpty,
              let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let certificate = certificates.first else {
            throw VerificationError(description: "Updates require a certificate-signed app; unsigned and ad-hoc builds cannot self-update")
        }
        return Identity(identifier: identifier, certificate: SecCertificateCopyData(certificate) as Data)
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw VerificationError(description: "App signature verification failed (\(status))")
        }
    }
}
