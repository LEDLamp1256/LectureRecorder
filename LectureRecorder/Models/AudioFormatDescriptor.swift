/// Describes the audio format a session's chunks are expected to use.
///
/// Phase 1 Step 1 does not yet open the microphone, so this value is not
/// derived from a live `AVAudioFormat` — it documents the target format the
/// manifest is written against. A later implementation step will replace
/// `defaultTarget` with the format actually negotiated with the input
/// hardware, and will keep this struct as the persisted representation.
nonisolated struct AudioFormatDescriptor: Codable, Equatable, Sendable {
    var sampleRate: Double
    var channelCount: UInt32
    var bitsPerChannel: UInt32
    var formatIdentifier: String

    static let defaultTarget = AudioFormatDescriptor(
        sampleRate: 44_100,
        channelCount: 1,
        bitsPerChannel: 32,
        formatIdentifier: "lpcm-float32"
    )
}
