import AVFoundation

/// Abstraction over the object that owns AVAudioEngine and delivers
/// captured microphone buffers.
///
/// Lifecycle:
/// idle -> prepare() -> prepared -> start() -> running -> stop() -> idle
///
/// `prepare()` is valid only from idle. `start()` is valid only after
/// a successful prepare(). `stop()` is safe from any state and must not
/// return until no buffer/failure callback from that cycle can fire again.
nonisolated protocol AudioCapturing: Sendable {
    /// Discovers and freezes the capture format for this cycle without
    /// starting buffer delivery.
    func prepare() throws -> AVAudioFormat

    /// Begins capture using exactly the format returned by prepare().
    ///
    /// If start() throws, onFailure must never later fire for that cycle.
    /// If start() succeeds, onFailure may fire at most once for a later
    /// asynchronous capture failure.
    func start(
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) throws

    /// Stops capture and waits for all already-admitted callbacks to finish.
    func stop() async
}
