import AVFoundation

/// Bridges a validated `AVAudioFormat` (as returned by
/// `AudioCapturing.prepare()`) to the persisted `AudioFormatDescriptor`
/// representation.
///
/// Deliberately lives in the audio service layer, not in `Models/`, so
/// `AudioFormatDescriptor.swift` stays free of an `AVFAudio`/
/// `AVFoundation` import.
///
/// `format` is expected to already satisfy the same invariant
/// `AudioCaptureService.negotiateAndValidateFormat` enforces before ever
/// returning a format from `prepare()`: `commonFormat == .pcmFormatFloat32`
/// and `isInterleaved == false`. This function does not re-validate that
/// invariant — it is a pure mapping, not a second validation gate — so
/// `bitsPerChannel` and `formatIdentifier` are the fixed values that
/// invariant implies (32-bit Float32 PCM), not independently derived
/// from `format` itself. Producing this descriptor does not by itself
/// prove what format was actually written to a `.caf` chunk file on
/// disk — that depends on how `AudioChunkWriter` constructs its
/// `AVAudioFile`, and must be verified against a real generated file.
func makeAudioFormatDescriptor(from format: AVAudioFormat) -> AudioFormatDescriptor {
    AudioFormatDescriptor(
        sampleRate: format.sampleRate,
        channelCount: format.channelCount,
        bitsPerChannel: 32,
        formatIdentifier: "lpcm-float32"
    )
}
