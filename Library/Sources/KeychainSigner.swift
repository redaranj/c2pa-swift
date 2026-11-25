// This file is licensed to you under the Apache License, Version 2.0
// (http://www.apache.org/licenses/LICENSE-2.0) or the MIT license
// (http://opensource.org/licenses/MIT), at your option.
//
// Unless required by applicable law or agreed to in writing, this software is
// distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR REPRESENTATIONS OF
// ANY KIND, either express or implied. See the LICENSE-MIT and LICENSE-APACHE
// files for the specific language governing permissions and limitations under
// each license.
//
//  KeychainSigner.swift
//

import C2PAC
import Foundation
import Security

extension Signer {
    /// Creates a signer using a private key stored in the iOS/macOS keychain.
    ///
    /// This initializer enables signing with keys stored in the system keychain,
    /// providing a secure way to manage signing credentials without exposing
    /// the private key data directly in your application.
    ///
    /// - Parameters:
    ///   - algorithm: The signing algorithm (ES256, ES384, ES512, PS256, PS384, or PS512).
    ///   - certificateChainPEM: The certificate chain in PEM format.
    ///   - tsa: Optional URL of a timestamp authority.
    ///   - keychainKeyTag: The keychain tag identifying the private key.
    ///
    /// - Throws: ``C2PAError`` if the key cannot be found or cannot sign with the algorithm,
    ///   which for an ECDSA algorithm includes a key on another curve. Also throws for Ed25519,
    ///   which is not supported by the keychain.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // First, ensure your key is in the keychain
    /// let signer = try Signer(
    ///     algorithm: .es256,
    ///     certificateChainPEM: certChainPEM,
    ///     tsa: URL(string: "http://timestamp.digicert.com"),
    ///     keychainKeyTag: "com.example.c2pa.signing.key"
    /// )
    ///
    /// let builder = try Builder(manifestJSON: manifestJSON)
    /// try builder.sign(
    ///     format: "image/jpeg",
    ///     source: sourceStream,
    ///     destination: destStream,
    ///     signer: signer
    /// )
    /// ```
    ///
    /// - Important: The key must already exist in the keychain before creating the signer.
    ///   Use standard keychain APIs to generate and store the key.
    ///
    /// - Note: Ed25519 is not supported because Keychain doesn't support this algorithm.
    ///
    /// - SeeAlso: ``SecureEnclaveSigner``, ``exportPublicKeyPEM(fromKeychainTag:)``
    public convenience init(
        algorithm: SigningAlgorithm,
        certificateChainPEM: String,
        tsa: URL? = nil,
        keychainKeyTag: String
    ) throws {
        // Fails here, not at the first signature, when the tag has no key or the key cannot
        // serve the algorithm.
        _ = try Signer.keychainKey(tag: keychainKeyTag, signingWith: algorithm)

        try self.init(
            algorithm: algorithm,
            certificateChainPEM: certificateChainPEM,
            tsa: tsa
        ) { data in
            // Looked up again here rather than captured, so the @Sendable closure holds only
            // Sendable values, not a SecKey or SecKeyAlgorithm whose Sendable conformance
            // varies by SDK. The lookup has already ruled out an algorithm without one.
            let privateKey = try Signer.keychainKey(tag: keychainKeyTag, signingWith: algorithm)

            var error: Unmanaged<CFError>?
            guard
                let signature = unsafe SecKeyCreateSignature(
                    privateKey,
                    algorithm.secKeyAlgo!,
                    data as CFData,
                    &error)
            else {
                throw unsafe C2PAError.signingFailed(error?.takeRetainedValue())
            }

            return signature as Data
        }
    }

    /// Finds the private key stored under `tag` and checks that it can sign with `algorithm`.
    ///
    /// `SecKeyIsAlgorithmSupported` only looks at the kind of key, so an elliptic curve key of
    /// any size passes for every ECDSA digest. Each ECDSA algorithm names one curve, so the size
    /// of the key is compared as well.
    private static func keychainKey(tag: String, signingWith algorithm: SigningAlgorithm) throws(C2PAError) -> SecKey {
        guard let secAlgorithm = algorithm.secKeyAlgo else {
            throw C2PAError.ed25519NotSupported
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true
        ]

        var item: CFTypeRef?
        let status = unsafe SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess,
            let privateKey = item as! SecKey?
        else {
            throw C2PAError.keySearchFailed(tag, status)
        }

        guard SecKeyIsAlgorithmSupported(privateKey, .sign, secAlgorithm) else {
            throw C2PAError.unsupportedAlgorithm(algorithm)
        }

        if let curveSize = algorithm.curveSizeInBits {
            let attributes = SecKeyCopyAttributes(privateKey) as? [String: Any]
            guard attributes?[kSecAttrKeySizeInBits as String] as? Int == curveSize else {
                throw C2PAError.unsupportedAlgorithm(algorithm)
            }
        }

        return privateKey
    }
}

extension SigningAlgorithm {
    /// The size in bits of the elliptic curve an ECDSA algorithm signs with, `nil` for the others.
    fileprivate var curveSizeInBits: Int? {
        switch self {
        case .es256: return 256
        case .es384: return 384
        case .es512: return 521
        case .ps256, .ps384, .ps512, .ed25519: return nil
        }
    }
}
