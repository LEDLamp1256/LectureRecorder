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
    ///
    /// `stop()` waits until this cycle's claimed `onFailure` invocation
    /// returns, but it does not wait for asynchronous work independently
    /// launched from inside that invocation. Because of that, `onFailure`
    /// must remain small and nonblocking: callers are responsible for
    /// tracking any asynchronous work they launch from it themselves, and
    /// must still tag that work with this cycle's identity, since a later
    /// cycle may already be running by the time it completes.
    func start(
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) throws

    /// Stops capture and waits for all already-admitted buffer callbacks
    /// to finish, and — if a failure was claimed for delivery this cycle —
    /// for that cycle's claimed `onFailure` invocation to return. It does
    /// not wait for any asynchronous work independently launched by that
    /// invocation; see `start()`.
    ///
    /// Returns the retained asynchronous capture failure for the most
    /// recently completed cycle, if any. A cycle "completes" the first
    /// time `stop()` finishes draining it; later `stop()` calls made
    /// while idle return that same retained outcome again. A successful
    /// `prepare()` resets it back to `nil` for the new cycle.
    @discardableResult
    func stop() async -> Error?
}
