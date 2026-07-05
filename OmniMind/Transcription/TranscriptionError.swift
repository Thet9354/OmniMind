//
//  TranscriptionError.swift
//  OmniMind
//
//  Failure taxonomy for the transcription subsystem (§5.5).
//

import Foundation

nonisolated enum TranscriptionError: Error, Equatable {
    /// The requested locale is not supported by the on-device transcriber.
    case localeUnsupported(String)
    /// The on-device model asset could not be installed (offline, disk full).
    case assetInstallationFailed
    /// The analyzer could not report a usable input audio format.
    case analyzerFormatUnavailable
}
