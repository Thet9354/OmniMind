//
//  AudioArchive.swift
//  OmniMind
//
//  Optional per-meeting audio retention: the transcription pump's already-
//  converted 16 kHz mono stream is encoded to AAC (~14 MB/hour), named by
//  the meeting's UUID — no schema change, presence checked on disk. Files
//  live in Application Support and are removed with their meeting.
//

import AVFAudio
import Foundation

nonisolated enum AudioArchive {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingAudio", isDirectory: true)
    }

    static func url(for meetingID: UUID) -> URL {
        directory.appendingPathComponent("\(meetingID.uuidString).m4a")
    }

    static func exists(for meetingID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: url(for: meetingID).path)
    }

    static func delete(for meetingID: UUID) {
        try? FileManager.default.removeItem(at: url(for: meetingID))
    }

    static func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }
}

/// Streams PCM buffers into an AAC file. Best-effort by contract: archival
/// must never fail a transcription, so callers `try?` every write.
nonisolated final class AudioArchiveWriter {
    private let file: AVAudioFile

    init(url: URL, format: AVAudioFormat) throws {
        try AudioArchive.ensureDirectory()
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings)
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        try file.write(from: buffer)
    }
}
