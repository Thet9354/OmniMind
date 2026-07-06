//
//  MeetingBundle.swift
//  OmniMind
//
//  Portable single-file meeting: transcript, AI outputs, and (optionally)
//  the audio archive, shared user-to-user over AirDrop / Files / any share
//  sheet — no server, preserving the app's privacy story. Embedding
//  vectors are deliberately NOT bundled: the importer re-embeds through
//  the normal backfill path, which keeps bundles small and immune to
//  embedding-model version drift between devices.
//
//  Wire format (little-endian):
//    bytes 0..<8   ASCII magic + format version  "OMNIMTG1"
//    bytes 8..<16  UInt64 length of the JSON payload
//    JSON payload  MeetingBundle (ISO-8601 dates)
//    remainder     raw AAC (.m4a) bytes; empty when no audio was retained
//

import Foundation

/// The Codable metadata envelope. IDs are preserved end-to-end so a bundle
/// imported twice is detected, and the audio archive keeps the meeting's
/// identity on the receiving device.
nonisolated struct MeetingBundle: Codable, Equatable, Sendable {
    struct BundleSegment: Codable, Equatable, Sendable {
        var id: UUID
        var text: String
        var startTime: TimeInterval
        var endTime: TimeInterval
        var confidence: Double
        var capturedAt: Date
    }

    var id: UUID
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var summaryText: String?
    var summaryMethod: String?
    var cleanedTranscript: String?
    var actionItems: [ExtractedActionItem]?
    var segments: [BundleSegment]
}

nonisolated enum MeetingBundleError: Error, Equatable {
    case notABundle          // wrong magic / hopelessly short
    case unsupportedVersion  // newer format than this build reads
    case corrupt             // length prefix or JSON doesn't parse
}

/// Encoder/decoder for the single-file wire format. Pure functions over
/// Data — trivially testable, no I/O opinions beyond bytes in, bytes out.
nonisolated enum MeetingBundleCodec {
    /// "OMNIMTG" + format digit. Bump the digit for breaking changes;
    /// readers reject newer digits instead of guessing.
    private static let magic = Data("OMNIMTG1".utf8)
    private static let magicPrefix = Data("OMNIMTG".utf8)
    static let fileExtension = "omnimind"

    static func encode(_ bundle: MeetingBundle, audio: Data?) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try encoder.encode(bundle)

        var data = Data(capacity: 16 + json.count + (audio?.count ?? 0))
        data.append(magic)
        var length = UInt64(json.count).littleEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(json)
        if let audio {
            data.append(audio)
        }
        return data
    }

    /// - Returns: the metadata envelope plus the audio bytes (nil when the
    ///   sender didn't retain audio).
    static func decode(_ data: Data) throws -> (bundle: MeetingBundle, audio: Data?) {
        guard data.count >= 16 else { throw MeetingBundleError.notABundle }
        guard data.prefix(7) == magicPrefix else { throw MeetingBundleError.notABundle }
        guard data.prefix(8) == magic else { throw MeetingBundleError.unsupportedVersion }

        let length = data.subdata(in: 8..<16).withUnsafeBytes {
            UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self))
        }
        // Bounds before Int() — a forged length must not trap the importer.
        guard length <= UInt64(data.count - 16) else { throw MeetingBundleError.corrupt }
        let jsonEnd = 16 + Int(length)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let bundle = try? decoder.decode(
            MeetingBundle.self, from: data.subdata(in: 16..<jsonEnd)
        ) else { throw MeetingBundleError.corrupt }

        let audio = data.count > jsonEnd ? data.subdata(in: jsonEnd..<data.count) : nil
        return (bundle, audio)
    }

    /// A share-sheet-friendly filename: the meeting title with characters
    /// that break file systems stripped, capped, never empty.
    static func filename(for title: String) -> String {
        var name = title.replacingOccurrences(
            of: "[/\\\\:?%*|\"<>\\n\\r]", with: " ", options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.count > 60 {
            name = String(name.prefix(60)).trimmingCharacters(in: .whitespaces)
        }
        if name.isEmpty { name = "Meeting" }
        return "\(name).\(fileExtension)"
    }
}
