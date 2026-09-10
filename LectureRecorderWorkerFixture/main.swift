import Darwin
import Foundation

// LectureRecorderWorkerFixture: a deterministic, argument-driven fake
// worker used only by T2's own tests. It never invokes a shell, never
// selects another executable, never touches the network, the microphone,
// or a model — it only implements the fixed set of modes below, selected
// by a `--mode=<name>` argument. Everything else about how it is launched
// (executable path, environment, working directory) is decided entirely
// by the caller (`FoundationProcessRunner`), never by this process itself.

struct ParsedArguments {
    var mode: String
    var delayMilliseconds: Int
    var sourcePath: String?
}

func parseArguments() -> ParsedArguments {
    var mode = "success"
    var delayMilliseconds = 300
    var sourcePath: String?

    for argument in CommandLine.arguments.dropFirst() {
        if argument.hasPrefix("--mode=") {
            mode = String(argument.dropFirst("--mode=".count))
        } else if argument.hasPrefix("--delay-ms=") {
            delayMilliseconds = Int(argument.dropFirst("--delay-ms=".count)) ?? delayMilliseconds
        } else if argument.hasPrefix("--source-path=") {
            sourcePath = String(argument.dropFirst("--source-path=".count))
        }
    }

    return ParsedArguments(mode: mode, delayMilliseconds: delayMilliseconds, sourcePath: sourcePath)
}

func readAllStdin() -> Data {
    FileHandle.standardInput.readDataToEndOfFile()
}

func writeStdout(_ data: Data) {
    FileHandle.standardOutput.write(data)
}

func writeStderr(_ data: Data) {
    FileHandle.standardError.write(data)
}

func decodeRequest(_ data: Data) -> FixtureRequestEnvelope? {
    try? JSONDecoder().decode(FixtureRequestEnvelope.self, from: data)
}

func encode(_ envelope: FixtureResponseEnvelope) -> Data {
    (try? JSONEncoder().encode(envelope)) ?? Data()
}

/// Builds a response that matches `request`'s identity exactly, unless one
/// of the `mismatch*` flags asks this fixture to deliberately corrupt a
/// specific identity field — used to exercise the worker client's identity
/// validation from the other side of a real process boundary.
func makeMatchingResponse(
    for request: FixtureRequestEnvelope,
    schemaVersion: Int = FixtureProtocolConstants.currentSchemaVersion,
    mismatchRequestID: Bool = false,
    mismatchAttemptID: Bool = false,
    mismatchSessionID: Bool = false,
    mismatchChunkSequence: Bool = false,
    mismatchSourceIdentity: Bool = false,
    wrongWorkerIdentifier: Bool = false,
    outcome: FixtureOutcome = .success,
    outputText: String = "fixture transcript",
    failureMessage: String = "fixture declared failure"
) -> FixtureResponseEnvelope {
    FixtureResponseEnvelope(
        schemaVersion: schemaVersion,
        requestID: mismatchRequestID ? UUID() : request.requestID,
        attemptID: mismatchAttemptID ? UUID() : request.attemptID,
        sessionID: mismatchSessionID ? UUID() : request.sessionID,
        chunkSequenceNumber: mismatchChunkSequence ? request.chunkSequenceNumber + 1 : request.chunkSequenceNumber,
        sourceIdentity: mismatchSourceIdentity ? request.sourceIdentity + "-corrupted" : request.sourceIdentity,
        workerIdentifier: wrongWorkerIdentifier ? "not-\(FixtureProtocolConstants.workerIdentifier)" : FixtureProtocolConstants.workerIdentifier,
        workerVersion: FixtureProtocolConstants.workerVersion,
        outcome: outcome,
        output: outcome == .success ? FixtureOutput(text: outputText) : nil,
        failure: outcome == .failure ? FixtureDeclaredFailure(message: failureMessage) : nil
    )
}

func largeFillerText(approximateByteCount: Int) -> String {
    String(repeating: "A", count: approximateByteCount)
}

// MARK: - Mode dispatch

let arguments = parseArguments()

switch arguments.mode {

case "success":
    let requestData = readAllStdin()
    guard let request = decodeRequest(requestData) else {
        exit(1)
    }
    writeStdout(encode(makeMatchingResponse(for: request, outcome: .success)))
    exit(0)

case "failure":
    let requestData = readAllStdin()
    guard let request = decodeRequest(requestData) else {
        exit(1)
    }
    writeStdout(encode(makeMatchingResponse(for: request, outcome: .failure)))
    exit(0)

case "nonzero-no-response":
    _ = readAllStdin()
    exit(7)

case "nonzero-with-success-json":
    // Deliberately fails loudly (distinct exit 9) on decode/encode failure
    // rather than silently writing nothing — this mode exists specifically
    // to prove a nonzero exit overrides even well-formed JSON, so it must
    // be indistinguishable from "no response" only when it actually failed
    // to build one, never as an unnoticed silent fallback.
    let requestData = readAllStdin()
    guard let request = decodeRequest(requestData) else { exit(9) }
    let responseData = encode(makeMatchingResponse(for: request, outcome: .success))
    guard !responseData.isEmpty else { exit(9) }
    writeStdout(responseData)
    exit(7)

case "empty-stdout":
    // Also used, with a large raw stdin payload, to exercise pipe-capacity
    // behavior at the process-runner layer without any JSON involved.
    _ = readAllStdin()
    exit(0)

case "echo-stdin":
    // Raw byte-level echo, no JSON involved — proves exact stdin bytes
    // (including large payloads exceeding pipe capacity) survive the
    // round trip unmodified.
    writeStdout(readAllStdin())
    exit(0)

case "malformed-json":
    _ = readAllStdin()
    writeStdout(Data("{not valid json".utf8))
    exit(0)

case "truncated-json":
    let requestData = readAllStdin()
    guard let request = decodeRequest(requestData) else { exit(1) }
    var full = encode(makeMatchingResponse(for: request))
    full = full.prefix(max(1, full.count / 2))
    writeStdout(full)
    exit(0)

case "multiple-json-values":
    let requestData = readAllStdin()
    guard let request = decodeRequest(requestData) else { exit(1) }
    let one = encode(makeMatchingResponse(for: request))
    writeStdout(one)
    writeStdout(one)
    exit(0)

case "trailing-garbage":
    let requestData = readAllStdin()
    guard let request = decodeRequest(requestData) else { exit(1) }
    writeStdout(encode(makeMatchingResponse(for: request)))
    writeStdout(Data(" not json garbage".utf8))
    exit(0)

case "unsupported-schema":
    let requestData = readAllStdin()
    guard let request = decodeRequest(requestData) else { exit(1) }
    writeStdout(encode(makeMatchingResponse(
        for: request,
        schemaVersion: FixtureProtocolConstants.unsupportedSchemaVersion
    )))
    exit(0)

case "mismatch-request-id":
    let requestData = readAllStdin()
    guard let request = decodeRequest(requestData) else { exit(1) }
    writeStdout(encode(makeMatchingResponse(for: request, mismatchRequestID: true)))
    exit(0)

case "mismatch-attempt-id":
    let requestData = readAllStdin()
    guard let request = decodeRequest(requestData) else { exit(1) }
    writeStdout(encode(makeMatchingResponse(for: request, mismatchAttemptID: true)))
    exit(0)

case "mismatch-session-id":
    let requestData = readAllStdin()
    guard let request = decodeRequest(requestData) else { exit(1) }
    writeStdout(encode(makeMatchingResponse(for: request, mismatchSessionID: true)))
    exit(0)

case "mismatch-chunk-sequence":
    let requestData = readAllStdin()
    guard let request = decodeRequest(requestData) else { exit(1) }
    writeStdout(encode(makeMatchingResponse(for: request, mismatchChunkSequence: true)))
    exit(0)

case "mismatch-source-identity":
    let requestData = readAllStdin()
    guard let request = decodeRequest(requestData) else { exit(1) }
    writeStdout(encode(makeMatchingResponse(for: request, mismatchSourceIdentity: true)))
    exit(0)

case "wrong-worker-identity":
    let requestData = readAllStdin()
    guard let request = decodeRequest(requestData) else { exit(1) }
    writeStdout(encode(makeMatchingResponse(for: request, wrongWorkerIdentifier: true)))
    exit(0)

case "large-stdout":
    let requestData = readAllStdin()
    guard let request = decodeRequest(requestData) else { exit(1) }
    let filler = largeFillerText(approximateByteCount: 16 * 1024 * 1024)
    writeStdout(encode(makeMatchingResponse(for: request, outputText: filler)))
    exit(0)

case "large-stderr":
    let requestData = readAllStdin()
    guard let request = decodeRequest(requestData) else { exit(1) }
    writeStderr(Data(largeFillerText(approximateByteCount: 4 * 1024 * 1024).utf8))
    writeStdout(encode(makeMatchingResponse(for: request)))
    exit(0)

case "large-both":
    let requestData = readAllStdin()
    guard let request = decodeRequest(requestData) else { exit(1) }
    let stdoutFiller = Data(largeFillerText(approximateByteCount: 16 * 1024 * 1024).utf8)
    let stderrFiller = Data(largeFillerText(approximateByteCount: 4 * 1024 * 1024).utf8)
    let chunkSize = 32 * 1024
    var offset = 0
    while offset < max(stdoutFiller.count, stderrFiller.count) {
        let end = min(offset + chunkSize, stdoutFiller.count)
        if offset < stdoutFiller.count {
            writeStdout(stdoutFiller.subdata(in: offset..<end))
        }
        let sEnd = min(offset + chunkSize, stderrFiller.count)
        if offset < stderrFiller.count {
            writeStderr(stderrFiller.subdata(in: offset..<sEnd))
        }
        offset += chunkSize
    }
    writeStdout(encode(makeMatchingResponse(for: request)))
    exit(0)

case "delayed-response":
    let requestData = readAllStdin()
    guard let request = decodeRequest(requestData) else { exit(1) }
    Thread.sleep(forTimeInterval: Double(arguments.delayMilliseconds) / 1000.0)
    writeStdout(encode(makeMatchingResponse(for: request)))
    exit(0)

case "respond-then-hang":
    // Writes a fully valid, matching success response, then hangs — proves
    // a complete response already sitting in the pipe is discarded once a
    // fatal intervention (e.g. timeout) has already claimed the outcome.
    let requestData = readAllStdin()
    guard let request = decodeRequest(requestData) else { exit(9) }
    writeStdout(encode(makeMatchingResponse(for: request, outcome: .success)))
    Thread.sleep(forTimeInterval: 30.0)
    exit(0)

case "invalid-outcome-success-with-no-output":
    // Hand-built JSON (bypassing the Codable struct, which cannot
    // represent this invalid shape) — outcome:"success" with output:null.
    let requestData = readAllStdin()
    guard let request = decodeRequest(requestData) else { exit(9) }
    let json = """
    {"schemaVersion":\(FixtureProtocolConstants.currentSchemaVersion),"requestID":"\(request.requestID.uuidString)","attemptID":"\(request.attemptID.uuidString)","sessionID":"\(request.sessionID.uuidString)","chunkSequenceNumber":\(request.chunkSequenceNumber),"sourceIdentity":"\(request.sourceIdentity)","workerIdentifier":"\(FixtureProtocolConstants.workerIdentifier)","workerVersion":"\(FixtureProtocolConstants.workerVersion)","outcome":"success","output":null,"failure":null}
    """
    writeStdout(Data(json.utf8))
    exit(0)

case "invalid-outcome-both-present":
    // Hand-built JSON: outcome:"success" with BOTH output and failure set.
    let requestData = readAllStdin()
    guard let request = decodeRequest(requestData) else { exit(9) }
    let json = """
    {"schemaVersion":\(FixtureProtocolConstants.currentSchemaVersion),"requestID":"\(request.requestID.uuidString)","attemptID":"\(request.attemptID.uuidString)","sessionID":"\(request.sessionID.uuidString)","chunkSequenceNumber":\(request.chunkSequenceNumber),"sourceIdentity":"\(request.sourceIdentity)","workerIdentifier":"\(FixtureProtocolConstants.workerIdentifier)","workerVersion":"\(FixtureProtocolConstants.workerVersion)","outcome":"success","output":{"text":"hi"},"failure":{"message":"also here"}}
    """
    writeStdout(Data(json.utf8))
    exit(0)

case "self-signal":
    // Genuine, timeout/cancellation-independent signal death: the child
    // kills itself immediately, unrelated to any runner-side escalation.
    _ = readAllStdin()
    raise(SIGABRT)
    exit(1) // unreachable if raise() behaves as expected

case "ignore-sigterm":
    signal(SIGTERM, SIG_IGN)
    _ = readAllStdin()
    // Outlast any reasonable test grace period; only SIGKILL ends this.
    Thread.sleep(forTimeInterval: 30.0)
    exit(0)

case "close-stdin-early":
    close(0)
    Thread.sleep(forTimeInterval: 0.3)
    exit(0)

case "delay-read-stdin":
    writeStderr(Data("waiting\n".utf8))
    Thread.sleep(forTimeInterval: Double(arguments.delayMilliseconds) / 1000.0)
    let requestData = readAllStdin()
    guard let request = decodeRequest(requestData) else { exit(1) }
    writeStdout(encode(makeMatchingResponse(for: request)))
    exit(0)

case "echo-args":
    let echoed = CommandLine.arguments.dropFirst(2) // skip executable path and --mode=echo-args
    let data = (try? JSONEncoder().encode(Array(echoed))) ?? Data()
    writeStdout(data)
    exit(0)

case "read-source-file":
    let requestData = readAllStdin()
    guard let request = decodeRequest(requestData), let sourcePath = arguments.sourcePath else { exit(1) }
    guard let fileData = FileManager.default.contents(atPath: sourcePath) else {
        writeStdout(encode(makeMatchingResponse(for: request, outcome: .failure, failureMessage: "could not read source file")))
        exit(0)
    }
    writeStdout(encode(makeMatchingResponse(for: request, outputText: "read \(fileData.count) bytes")))
    exit(0)

default:
    FileHandle.standardError.write(Data("unknown fixture mode: \(arguments.mode)\n".utf8))
    exit(64)
}
