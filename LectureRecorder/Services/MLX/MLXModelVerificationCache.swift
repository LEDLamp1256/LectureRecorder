import Foundation

/// Process-lifetime memory of one successful full `MLXModelVerifier`
/// verification, keyed by the verified files' `MLXModelFileIdentity`.
///
/// - The first check of an identity runs the full SHA-256 verification,
///   off the caller's actor (never on `@MainActor`), in a single flight
///   shared by every concurrent caller — so availability checks and the
///   first model load never hash the same files twice.
/// - Later checks of an unchanged identity reuse that success after only a
///   metadata comparison.
/// - A changed identity (replaced, rewritten, touched, moved, or a
///   different directory/revision/manifest) verifies again in full.
/// - A failed verification is never remembered; the next check verifies
///   again. A verification whose files changed while being hashed fails.
///
/// Held only in memory: never persisted across launches.
actor MLXModelVerificationCache {
    typealias IdentityProvider = @Sendable (_ applicationSupportRoot: URL) -> MLXModelFileIdentity?
    typealias Verifier = @Sendable (_ applicationSupportRoot: URL) throws -> URL

    private let identityProvider: IdentityProvider
    private let verifier: Verifier
    private let diagnostics: AcceptanceDiagnosticLogger
    private let modelIdentifier: String
    private let verifications = MLXSingleFlight<MLXModelFileIdentity?, URL>()

    init(
        descriptor: MLXModelDescriptor,
        diagnostics: AcceptanceDiagnosticLogger = .shared
    ) {
        self.init(
            modelIdentifier: descriptor.modelIdentifier,
            identityProvider: { root in
                MLXModelVerifier.fileIdentity(descriptor: descriptor, applicationSupportRoot: root)
            },
            verifier: { root in
                try MLXModelVerifier.verify(descriptor: descriptor, applicationSupportRoot: root)
            },
            diagnostics: diagnostics
        )
    }

    /// Test seam: substitutes the identity and full-verification steps so
    /// tests never hash a real multi-gigabyte model.
    init(
        modelIdentifier: String,
        identityProvider: @escaping IdentityProvider,
        verifier: @escaping Verifier,
        diagnostics: AcceptanceDiagnosticLogger = .shared
    ) {
        self.modelIdentifier = modelIdentifier
        self.identityProvider = identityProvider
        self.verifier = verifier
        self.diagnostics = diagnostics
    }

    /// The verified model directory, reusing a prior success only when the
    /// files' identity is unchanged.
    func verifiedModelDirectory(applicationSupportRoot root: URL) async throws -> URL {
        let identity = identityProvider(root)
        return try await verifications.value(for: identity) {
            [identityProvider, verifier, diagnostics, modelIdentifier] in
            diagnostics.log(
                AcceptanceDiagnosticEvent.MLX.modelVerificationStarted,
                metadata: ["modelIdentifier": .string(modelIdentifier)]
            )
            let start = AcceptanceDiagnosticLogger.startInstant()
            do {
                let directory = try verifier(root)
                // Cached only if the identity read before hashing still
                // describes the files after hashing.
                guard let identity, identityProvider(root) == identity else {
                    throw MLXModelVerificationError.modelFilesChangedDuringVerification
                }
                diagnostics.log(
                    AcceptanceDiagnosticEvent.MLX.modelVerificationCompleted,
                    metadata: ["modelIdentifier": .string(modelIdentifier)],
                    elapsedSeconds: AcceptanceDiagnosticLogger.elapsedSeconds(since: start)
                )
                return directory
            } catch {
                diagnostics.log(
                    AcceptanceDiagnosticEvent.MLX.modelVerificationFailed,
                    metadata: [
                        "modelIdentifier": .string(modelIdentifier),
                        "errorType": .string(String(describing: type(of: error))),
                    ],
                    elapsedSeconds: AcceptanceDiagnosticLogger.elapsedSeconds(since: start)
                )
                throw error
            }
        }
    }

    /// How many uncancelled checks have reached the shared verification
    /// flight — observation only, so tests can wait until concurrent checks
    /// have joined it.
    var verificationRequestCountForTesting: Int {
        get async { await verifications.requestCountForTesting }
    }
}
