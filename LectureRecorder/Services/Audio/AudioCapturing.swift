import AVFoundation

/// Abstraction over "the thing that owns AVAudioEngine and delivers
/// captured microphone buffers." Exists so a future
/// `MockAudioCaptureService` can drive `AudioChunkWriter` in tests
/// without real hardware, and so `AudioCaptureService`'s AVAudioEngine
/// specifics stay isolated from whatever consumes its output.
///
/// This file defines the CONTRACT ONLY. The concrete AVAudioEngine-backed
/// implementation (`AudioCaptureService`) lands in a later batch, once
/// `AudioChunkWriter` — the thing it will feed — exists and is tested.
///
/// ## Lifecycle: one `prepare()`/`start()`/`stop()` triplet per recording
/// A single conforming instance must support running the full cycle more
/// than once, because LectureRecorder allows starting a second,
/// independent session without recreating the app environment:
///
/// ```
/// idle -> prepare() -> start() -> stop() -> idle -> prepare() -> start() -> stop() -> ...
/// ```
///
/// `prepare()` is called once *per recording*, not once for the lifetime
/// of the service. Each `stop()` returns the instance to a state where
/// `prepare()` can be called again to begin an independent new session.
/// `stop()` remains idempotent *within* one cycle (safe to call more than
/// once after a given `start()`) — that does not change here.
///
/// ## Two-stage start (why `prepare()` and `start()` are separate)
/// `AudioChunkWriter` must be constructed with the actual negotiated
/// capture format *before* any buffer can reach it — there's no safe way
/// to hand a buffer to a writer that doesn't exist yet. Combining
/// "discover the format" and "begin delivering buffers" into a single
/// call (e.g. `start(onBuffer:) -> AVAudioFormat`) creates exactly that
/// race: buffer delivery could begin as a side effect of the call before
/// the caller ever sees the returned format and builds the writer.
///
/// Splitting it in two removes the race structurally: `prepare()`
/// discovers/configures the format and returns it *without* starting
/// delivery, so the caller can safely construct `AudioChunkWriter` first
/// and only then call `start(onBuffer:)`, which is the sole point where
/// buffers can begin flowing.
///
/// ## Prepared-format invariant
/// The `AVAudioFormat` returned by `prepare()` is a binding commitment:
/// every buffer subsequently delivered to `onBuffer` during that same
/// cycle must be in exactly that format. This matters because the
/// caller constructs `AudioChunkWriter` from `prepare()`'s return value
/// *before* calling `start(onBuffer:)` — if the input device or
/// configuration changed in between (e.g. the user switched microphones
/// at the OS level) such that `start()` would actually begin delivering
/// a different format, `start()` must detect that and throw instead of
/// beginning delivery. It must never silently start delivering buffers
/// in a format other than what `prepare()` promised.
///
/// The equivalent case *during* an active recording — the input device
/// changing format mid-cycle, after `start()` already began delivering
/// buffers — is not something this protocol can prevent outright (the
/// hardware can change out from under any running capture). In that
/// case the implementation must route the resulting failure through the
/// normal capture-failure path rather than silently changing formats
/// mid-stream. `AudioChunkWriter` already rejects any buffer that
/// doesn't match its constructed format (`bufferFormatMismatch`), so
/// this failure mode has a defined destination once `AudioCaptureService`
/// is wired up to it — it isn't relying on `AudioCapturing` to prevent
/// the mismatch from ever reaching the writer.
nonisolated protocol AudioCapturing: Sendable {
    /// Discovers and configures the format capture will actually
    /// produce for this recording cycle, without starting buffer
    /// delivery. Must be called once per cycle, before `start(onBuffer:)`
    /// — see the type-level lifecycle diagram.
    ///
    /// The Phase 2A audio contract requires the returned format to
    /// reflect the input's true native sample rate and channel count —
    /// no forced 44.1kHz, no forced mono down-mixing. `AVAudioInputNode`
    /// exposes both an input-side format and an output/tap-side format
    /// for a given bus, and Apple does not document these as always
    /// identical — `AVAudioEngine` can interpose format conversion
    /// between them. It is `AudioCaptureService`'s responsibility (in a
    /// later batch) to explicitly inspect whichever formats are relevant
    /// and confirm no resampling or channel down-mixing is occurring,
    /// rather than assuming any single property call is automatically
    /// "the native hardware format." Float32, non-interleaved is an
    /// acceptable *processing representation* for the returned format —
    /// the constraint is on preserving the source's rate and channel
    /// count, not on the numeric representation.
    ///
    /// - Returns: the format subsequent captured buffers are committed
    ///   to using for this cycle (see the prepared-format invariant
    ///   above). Use this exact format to construct the session's
    ///   `AudioChunkWriter` before calling `start(onBuffer:)`.
    func prepare() throws -> AVAudioFormat

    /// Begins delivering captured buffers to `onBuffer`, in the exact
    /// format `prepare()` returned for this cycle. Must only be called
    /// after `prepare()` has returned successfully for this cycle, and
    /// only once the caller has finished constructing whatever needs
    /// that format (e.g. `AudioChunkWriter`) — nothing downstream of
    /// `onBuffer` should be built after this call.
    ///
    /// If the input device or configuration has changed since
    /// `prepare()` such that capture would no longer produce that exact
    /// format, this must throw before delivering any buffer — never
    /// silently begin delivery in a different format (see the
    /// prepared-format invariant above).
    ///
    /// `onBuffer` is called directly from (or immediately downstream of)
    /// the realtime audio tap for every captured buffer. It must return
    /// quickly and must never block, `await`, throw, or perform I/O —
    /// its only job is to hand the buffer off to something like
    /// `AudioChunkWriter.acceptBuffer(_:)`. It runs on an undefined,
    /// non-Main thread, and each buffer passed to it must be one the
    /// implementation will never touch again afterward (a defensive copy
    /// the receiver now exclusively owns).
    ///
    /// - Important: Implementations MUST guarantee that once `stop()`
    ///   returns, `onBuffer` will never be invoked again — including for
    ///   any invocation already in progress when `stop()` was called.
    ///   Whoever drives a session's `AudioChunkWriter` depends on this:
    ///   they must call `stop()` (or otherwise obtain this guarantee)
    ///   *before* calling `AudioChunkWriter.finishRecording()`. See
    ///   `AudioChunkWriter`'s type-level documentation for exactly why
    ///   this ordering is what makes Stop race-free. This guarantee must
    ///   be actively enforced by the implementation (e.g. an
    ///   in-flight-callback gate) — `removeTap(onBus:)` alone is not
    ///   documented by Apple to provide it.
    func start(
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) throws

    /// Stops capture for the current cycle. Does not return until
    /// `onBuffer` is guaranteed to never be called again for this cycle
    /// (see `start`'s contract). Safe to call more than once within a
    /// cycle; a second call is a no-op. After `stop()` returns, the
    /// instance is back in the idle state and `prepare()` may be called
    /// again to begin an independent new recording cycle.
    func stop() async
}
