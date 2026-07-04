//
//  CaptureError.swift
//  OmniMind
//
//  Failure taxonomy for the audio capture graph.
//

import Foundation

nonisolated enum CaptureError: Error, Equatable {
    /// `bufferStream()` was called while a capture session is already live.
    case alreadyRunning
    /// The input node reported a zero sample rate — no usable microphone.
    case noInputAvailable
    /// AVAudioConverter could not be built for the input → target formats.
    case converterUnavailable
    /// The converter reported an error mid-stream.
    case conversionFailed
    /// Could not allocate a PCM buffer (extreme memory pressure).
    case bufferAllocationFailed
}
