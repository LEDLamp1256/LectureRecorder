import Foundation

/// Every way `TranscriptionWorkerClient.submit` can fail to produce a
/// trustworthy `Output`. Deliberately distinct from `TranscriptionFailureCategory`/
/// `TranscriptionEngineFailing` (T1's closed vocabulary for "a `Transcribing`
/// conformer's own attempt failed") — a future T3 adapter is responsible for
/// translating a `WorkerClientFailure` into that vocabulary; this type never
/// reaches into T1's taxonomy directly.
nonisolated enum WorkerClientFailure: LocalizedError, Sendable, Equatable {
    case locatorFailure(EmbeddedWorkerLocatorError)
    case requestEncodingFailed(underlying: String)
    case process(ProcessRunFailure)
    /// `stderr` is the full runner-bounded capture (already capped at the
    /// invocation's `maximumStderrBytes`, e.g. up to 1 MiB) — preserved
    /// here as data for any future diagnostic consumer, but
    /// `errorDescription` deliberately never interpolates it in full; see
    /// `diagnosticPreview(of:runnerTruncated:)`.
    case processFailure(exitStatus: Int32?, signal: Int32?, stderr: Data, stderrTruncated: Bool)
    case missingResponse
    case malformedResponse(underlying: String)
    case unsupportedSchemaVersion(Int)
    case identityMismatch(field: String)
    case unexpectedWorkerIdentity(expected: String, actual: String)
    case invalidOutcomeShape

    var errorDescription: String? {
        switch self {
        case .locatorFailure(let underlying):
            return underlying.errorDescription
        case .requestEncodingFailed(let underlying):
            return "Failed to encode worker request: \(underlying)"
        case .process(let underlying):
            return underlying.errorDescription
        case .processFailure(let exitStatus, let signal, let stderr, let stderrTruncated):
            let reason = signal.map { "signal \($0)" } ?? "exit status \(exitStatus ?? -1)"
            return "Worker process terminated abnormally (\(reason)). \(Self.diagnosticPreview(of: stderr, runnerTruncated: stderrTruncated))"
        case .missingResponse:
            return "Worker process exited zero but produced no response."
        case .malformedResponse(let underlying):
            return "Worker response could not be decoded: \(underlying)"
        case .unsupportedSchemaVersion(let version):
            return "Worker response declared unsupported schema version \(version)."
        case .identityMismatch(let field):
            return "Worker response's \(field) did not match the request."
        case .unexpectedWorkerIdentity(let expected, let actual):
            return "Worker response identified itself as \(Self.boundedIdentityPreview(actual)), expected \(expected)."
        case .invalidOutcomeShape:
            return "Worker response's outcome/output/failure shape was inconsistent."
        }
    }

    /// Caps any stderr excerpt embedded in a diagnostic string at
    /// ~4 KiB of *rendered output* — deliberately much tighter than the
    /// runner's own up-to-1-MiB retention bound, which governs what is
    /// *captured*, not what is safe to fold into a single
    /// `errorDescription` string. Bounding only the input byte slice
    /// before decoding is not sufficient: `String(decoding:as: UTF8.self)`
    /// replaces each invalid byte with U+FFFD, a 3-byte UTF-8 sequence, so
    /// a 4 KiB slice of invalid bytes can decode to a ~12 KiB string. This
    /// walks the decoded scalars and stops once the *rendered* text would
    /// exceed the limit, so the returned string's UTF-8 byte count is
    /// actually bounded regardless of the input's validity. Never crashes
    /// on invalid UTF-8 or on truncating mid-multi-byte-sequence: decoding
    /// via `String(decoding:as:)` already replaced any invalid bytes
    /// before this ever walks scalars, and appending whole
    /// `Unicode.Scalar`s one at a time can never split one.
    private static func diagnosticPreview(of stderr: Data, runnerTruncated: Bool) -> String {
        guard !stderr.isEmpty else {
            return "No stderr output."
        }
        let byteLimit = 4 * 1024
        let inputPreview = stderr.prefix(byteLimit)
        let decoded = String(decoding: inputPreview, as: UTF8.self)

        var boundedText = ""
        var renderedByteCount = 0
        var outputWasTruncated = false
        for scalar in decoded.unicodeScalars {
            let scalarByteCount = String(scalar).utf8.count
            guard renderedByteCount + scalarByteCount <= byteLimit else {
                outputWasTruncated = true
                break
            }
            boundedText.unicodeScalars.append(scalar)
            renderedByteCount += scalarByteCount
        }

        let wasTruncated = runnerTruncated || inputPreview.count < stderr.count || outputWasTruncated
        let truncationNote = wasTruncated ? " [stderr truncated]" : ""
        return "stderr (\(stderr.count) bytes captured): \(boundedText)\(truncationNote)"
    }

    /// `workerIdentifier` is a decoded JSON string field bounded only by
    /// the invocation's overall stdout cap (default 8 MiB) — a worker
    /// (buggy or adversarial) could return an enormous value here, and
    /// nothing upstream of this diagnostic bounds it. Caps the rendered
    /// preview at 256 bytes using the same scalar-walking approach as
    /// `diagnosticPreview` (never splits a character, never crashes on
    /// pathological input) — this is a separate, much smaller bound than
    /// the 4 KiB stderr preview, since a worker identifier has no
    /// legitimate reason to be long at all.
    private static func boundedIdentityPreview(_ identity: String) -> String {
        let byteLimit = 256
        var bounded = ""
        var renderedByteCount = 0
        var wasTruncated = false
        for scalar in identity.unicodeScalars {
            let scalarByteCount = String(scalar).utf8.count
            guard renderedByteCount + scalarByteCount <= byteLimit else {
                wasTruncated = true
                break
            }
            bounded.unicodeScalars.append(scalar)
            renderedByteCount += scalarByteCount
        }
        return wasTruncated ? "\(bounded)… [truncated, \(identity.utf8.count) bytes total]" : bounded
    }
}

/// The three-way outcome a real caller must distinguish, matching the
/// approved exit-code decision table exactly: a trusted success, a
/// trusted-but-negative structured worker failure, or an untrusted
/// infrastructure failure. Deliberately not collapsed into `Result`'s two
/// cases — `workerDeclaredFailure` is trusted content, `infrastructureFailure`
/// never is, and callers must not be able to blur that distinction.
nonisolated enum WorkerInvocationOutcome<Output: Sendable>: Sendable {
    case success(Output)
    case workerDeclaredFailure(WorkerDeclaredFailure)
    case infrastructureFailure(WorkerClientFailure)
}

nonisolated struct WorkerInvocationLimits: Sendable {
    var maximumRequestBytes: Int
    var maximumStdoutBytes: Int
    var maximumStderrBytes: Int
    var overallTimeout: TimeInterval
    var gracePeriod: TimeInterval

    init(
        maximumRequestBytes: Int = 1 * 1024 * 1024,
        maximumStdoutBytes: Int = 8 * 1024 * 1024,
        maximumStderrBytes: Int = 1 * 1024 * 1024,
        overallTimeout: TimeInterval,
        gracePeriod: TimeInterval = 2.0
    ) {
        self.maximumRequestBytes = maximumRequestBytes
        self.maximumStdoutBytes = maximumStdoutBytes
        self.maximumStderrBytes = maximumStderrBytes
        self.overallTimeout = overallTimeout
        self.gracePeriod = gracePeriod
    }
}

/// Encodes a versioned, identity-bearing request; launches the fixed,
/// trusted embedded worker helper via `LocalProcessRunning`; and validates
/// the response against the approved protocol/exit-code decision table
/// before ever trusting its content. Never accepts an executable path from
/// a caller — always resolves via `EmbeddedWorkerLocator`, the one trusted
/// source. Has no production call site in T2: nothing in `SessionManager`,
/// `AppEnvironment`, or `Transcribing` references this type.
///
/// ## Where the cancellation commitment point actually is
/// `FoundationProcessRunner`'s own `ProcessInvocationState` is the
/// authoritative commitment boundary: once it commits success, a later
/// cancellation of the calling task cannot retroactively replace that
/// outcome — that rule is about the *process-level* invocation (did the
/// child run to completion under the runner's care, confirmed terminated,
/// I/O joined). `classify`/`decodeAndValidate` below run strictly after
/// `processRunner.run(request)` has already returned that already-
/// committed result; they are a separate, fast, synchronous, side-effect-
/// free computation over bytes that already fully exist — there is no
/// `await` and no `Task.checkCancellation()` inside either, so Swift's
/// cooperative cancellation cannot preempt them mid-computation even in
/// principle. This is intentional, not an oversight: a caller whose own
/// task is cancelled after the process-level commitment has already
/// happened still receives a fully-computed, trustworthy `submit()`
/// result reflecting bytes that were already fully and successfully
/// obtained: rejecting or discarding that result post hoc would not make
/// the invocation any less real, only harder to observe.
nonisolated struct TranscriptionWorkerClient: Sendable {
    private let processRunner: any LocalProcessRunning
    private let expectedWorkerIdentifier: String

    init(
        processRunner: any LocalProcessRunning = FoundationProcessRunner(),
        expectedWorkerIdentifier: String = "LectureRecorderWorkerFixture"
    ) {
        self.processRunner = processRunner
        self.expectedWorkerIdentifier = expectedWorkerIdentifier
    }

    func submit<Payload: Codable & Sendable, Output: Codable & Sendable>(
        payload: Payload,
        identity: WorkerRequestIdentity,
        outputType: Output.Type,
        arguments: [String] = [],
        limits: WorkerInvocationLimits
    ) async -> WorkerInvocationOutcome<Output> {
        let executableURL: URL
        switch EmbeddedWorkerLocator.resolve() {
        case .success(let url):
            executableURL = url
        case .failure(let locatorError):
            return .infrastructureFailure(.locatorFailure(locatorError))
        }

        let envelope = WorkerRequestEnvelope(
            schemaVersion: WorkerProtocolConstants.currentSchemaVersion,
            requestID: identity.requestID,
            attemptID: identity.attemptID,
            sessionID: identity.sessionID,
            chunkSequenceNumber: identity.chunkSequenceNumber,
            sourceIdentity: identity.sourceIdentity,
            payload: payload
        )

        let requestData: Data
        do {
            requestData = try JSONEncoder().encode(envelope)
        } catch {
            return .infrastructureFailure(.requestEncodingFailed(underlying: String(describing: error)))
        }

        let request = ProcessInvocationRequest(
            executableURL: executableURL,
            arguments: arguments,
            stdin: requestData,
            environmentPolicy: .empty,
            workingDirectoryURL: nil,
            maximumStdinBytes: limits.maximumRequestBytes,
            maximumStdoutBytes: limits.maximumStdoutBytes,
            maximumStderrBytes: limits.maximumStderrBytes,
            overallTimeout: limits.overallTimeout,
            gracePeriod: limits.gracePeriod
        )

        switch await processRunner.run(request) {
        case .failure(let processFailure):
            return .infrastructureFailure(.process(processFailure))
        case .success(let result):
            return classify(result: result, identity: identity, outputType: outputType)
        }
    }

    private func classify<Output: Codable & Sendable>(
        result: ProcessRunResult,
        identity: WorkerRequestIdentity,
        outputType: Output.Type
    ) -> WorkerInvocationOutcome<Output> {
        switch result.terminationReason {
        case .exited(let status) where status == 0:
            return decodeAndValidate(result: result, identity: identity, outputType: outputType)
        case .exited(let status):
            return .infrastructureFailure(.processFailure(
                exitStatus: status,
                signal: nil,
                stderr: result.stderr,
                stderrTruncated: result.stderrTruncated
            ))
        case .uncaughtSignal(let signalNumber):
            return .infrastructureFailure(.processFailure(
                exitStatus: nil,
                signal: signalNumber,
                stderr: result.stderr,
                stderrTruncated: result.stderrTruncated
            ))
        }
    }

    /// Only reachable once `result.terminationReason == .exited(status: 0)`
    /// — a nonzero or signaled exit never reaches this method, so JSON
    /// found in `result.stdout` for such a process is never even
    /// considered here, regardless of how well-formed it looks.
    private func decodeAndValidate<Output: Codable & Sendable>(
        result: ProcessRunResult,
        identity: WorkerRequestIdentity,
        outputType: Output.Type
    ) -> WorkerInvocationOutcome<Output> {
        guard !result.stdout.isEmpty else {
            return .infrastructureFailure(.missingResponse)
        }

        let response: WorkerResponseEnvelope<Output>
        do {
            // Empirically confirmed on this toolchain (Xcode 26.6, Swift
            // 6.3.3): `JSONDecoder.decode` already throws
            // `DecodingError.dataCorrupted` for trailing non-whitespace
            // bytes, multiple top-level JSON values, and truncated JSON —
            // only trailing JSON whitespace is tolerated. See
            // `WorkerProtocolTests` for the permanent regression test.
            // No hand-written framing scanner is needed.
            response = try JSONDecoder().decode(WorkerResponseEnvelope<Output>.self, from: result.stdout)
        } catch {
            return .infrastructureFailure(.malformedResponse(underlying: String(describing: error)))
        }

        guard response.schemaVersion == WorkerProtocolConstants.currentSchemaVersion else {
            return .infrastructureFailure(.unsupportedSchemaVersion(response.schemaVersion))
        }
        guard response.requestID == identity.requestID else {
            return .infrastructureFailure(.identityMismatch(field: "requestID"))
        }
        guard response.attemptID == identity.attemptID else {
            return .infrastructureFailure(.identityMismatch(field: "attemptID"))
        }
        guard response.sessionID == identity.sessionID else {
            return .infrastructureFailure(.identityMismatch(field: "sessionID"))
        }
        guard response.chunkSequenceNumber == identity.chunkSequenceNumber else {
            return .infrastructureFailure(.identityMismatch(field: "chunkSequenceNumber"))
        }
        guard response.sourceIdentity == identity.sourceIdentity else {
            return .infrastructureFailure(.identityMismatch(field: "sourceIdentity"))
        }
        guard response.workerIdentifier == expectedWorkerIdentifier else {
            return .infrastructureFailure(.unexpectedWorkerIdentity(
                expected: expectedWorkerIdentifier,
                actual: response.workerIdentifier
            ))
        }

        switch response.outcome {
        case .success:
            guard let output = response.output, response.failure == nil else {
                return .infrastructureFailure(.invalidOutcomeShape)
            }
            return .success(output)
        case .failure:
            guard let failure = response.failure, response.output == nil else {
                return .infrastructureFailure(.invalidOutcomeShape)
            }
            return .workerDeclaredFailure(failure)
        }
    }
}
