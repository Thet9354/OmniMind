//
//  AudioBufferBridge.swift
//  OmniMind
//
//  The single legal crossing from the real-time audio render thread into
//  structured concurrency.
//

import AVFAudio
import Synchronization

/// Bridges a real-time producer into an `AsyncStream` with a bounded,
/// drop-oldest queue.
///
/// `yield(_:)` is safe to call from the `AVAudioEngine` render tap: it
/// performs one lock-free enqueue plus, on shed load, one relaxed atomic
/// increment. No locks, no allocation, no actor hops. Dropping the *oldest*
/// audio under backpressure is deliberate — stale audio is worthless to a
/// live transcriber, while blocking the render thread would glitch capture
/// for the whole system (§5.2 of the design spec).
///
/// `@unchecked Sendable`: `AVAudioPCMBuffer` is not `Sendable`, but every
/// buffer moves through exactly one producer (the tap) to exactly one
/// consumer (the transcription pump) and the producer never touches it
/// again — a linear region transfer the compiler cannot prove across the
/// Objective-C tap boundary. The continuation and atomic counter are both
/// themselves thread-safe.
nonisolated final class AudioBufferBridge: @unchecked Sendable {
    let stream: AudioBufferStream
    private let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    private let drops = Atomic<Int>(0)

    /// - Parameter capacity: maximum queued buffers before the oldest are
    ///   shed (live capture). Pass `nil` for unbounded buffering (file
    ///   replay, where shedding would silently corrupt the transcript).
    init(capacity: Int?) {
        let policy: AsyncStream<AVAudioPCMBuffer>.Continuation.BufferingPolicy =
            if let capacity { .bufferingNewest(capacity) } else { .unbounded }
        let (base, continuation) = AsyncStream.makeStream(
            of: AVAudioPCMBuffer.self,
            bufferingPolicy: policy
        )
        self.stream = AudioBufferStream(base: base)
        self.continuation = continuation
    }

    /// Real-time safe. The sole action permitted on the render thread.
    func yield(_ buffer: AVAudioPCMBuffer) {
        // The compiler cannot prove the buffer's region transfers linearly
        // through the ObjC tap callback, so the opt-out is laundered here —
        // at the one documented crossing — rather than at every call site.
        // Invariant: the producer never touches a buffer after yielding it.
        nonisolated(unsafe) let transferred = buffer
        if case .dropped = continuation.yield(transferred) {
            drops.wrappingAdd(1, ordering: .relaxed)
        }
    }

    func finish() {
        continuation.finish()
    }

    /// Buffers shed under backpressure since this bridge was created.
    /// Surfaced to the UI as a "degraded capture" signal when it grows.
    var droppedBufferCount: Int {
        drops.load(ordering: .relaxed)
    }
}

/// Sendable view of the capture stream, so it can cross from the capture
/// actor to its consumer. `AsyncStream` is only conditionally `Sendable`
/// (its Element must be), so this wrapper carries the same linear-transfer
/// justification as `AudioBufferBridge`: exactly one consumer iterates it,
/// and each buffer is owned by whoever holds it.
nonisolated struct AudioBufferStream: AsyncSequence, @unchecked Sendable {
    typealias Element = AVAudioPCMBuffer

    fileprivate let base: AsyncStream<AVAudioPCMBuffer>

    func makeAsyncIterator() -> AsyncStream<AVAudioPCMBuffer>.AsyncIterator {
        base.makeAsyncIterator()
    }
}
