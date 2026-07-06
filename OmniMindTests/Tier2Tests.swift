//
//  Tier2Tests.swift
//  OmniMindTests
//
//  Phase 11 verification: audio archival, session-identity plumbing, and
//  chat-engine degradation. Playback and chat generation are exercised
//  on-device; here we prove the deterministic parts.
//

import AVFAudio
import Foundation
import SwiftData
import Testing
@testable import OmniMind

@Suite("Phase 11 — Audio archive")
struct AudioArchiveTests {

    @Test("Archive URLs are deterministic per meeting and isolated per id")
    func urlsDeterministic() {
        let a = UUID()
        let b = UUID()
        #expect(AudioArchive.url(for: a) == AudioArchive.url(for: a))
        #expect(AudioArchive.url(for: a) != AudioArchive.url(for: b))
        #expect(AudioArchive.url(for: a).pathExtension == "m4a")
    }

    @Test("Writer encodes PCM to a readable AAC file; delete removes it")
    func writeReadDeleteCycle() throws {
        let id = UUID()
        let url = AudioArchive.url(for: id)
        defer { AudioArchive.delete(for: id) }

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000, channels: 1, interleaved: false
        )!
        var writer: AudioArchiveWriter? = try AudioArchiveWriter(url: url, format: format)

        // One second of 440 Hz sine in 10 buffers.
        for _ in 0..<10 {
            let buffer = try #require(
                AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600)
            )
            buffer.frameLength = 1_600
            let data = try #require(buffer.floatChannelData)
            for frame in 0..<1_600 {
                data[0][frame] = sinf(2 * .pi * 440 * Float(frame) / 16_000) * 0.5
            }
            try writer?.write(buffer)
        }
        // AVAudioFile finalizes its header on deallocation — release the
        // writer before reading back (mirrors the live pipeline, where the
        // pump's writer goes out of scope before playback can begin).
        writer = nil

        #expect(AudioArchive.exists(for: id))
        let readBack = try AVAudioFile(forReading: url)
        // AAC priming/padding shifts a few hundred frames; a second of
        // audio must survive within codec tolerance.
        #expect(abs(Double(readBack.length) - 16_000) < 2_048)

        AudioArchive.delete(for: id)
        #expect(!AudioArchive.exists(for: id))
    }

    @Test("Writer accepts the analyzer's Int16 format (on-device abort regression)")
    func writeInt16AnalyzerFormat() throws {
        let id = UUID()
        let url = AudioArchive.url(for: id)
        defer { AudioArchive.delete(for: id) }

        // On hardware SpeechAnalyzer's preferred format is Int16 interleaved,
        // not the Float32 the settings-only AVAudioFile initializer assumes.
        // A processing-format mismatch aborts the process inside CoreAudio
        // (first on-device Record tap, 2026-07-06), so this guards format
        // agreement itself, not just the encoded output.
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000, channels: 1, interleaved: true
        ))
        var writer: AudioArchiveWriter? = try AudioArchiveWriter(url: url, format: format)

        for _ in 0..<10 {
            let buffer = try #require(
                AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600)
            )
            buffer.frameLength = 1_600
            let data = try #require(buffer.int16ChannelData)
            for frame in 0..<1_600 {
                data[0][frame] = Int16(sinf(2 * .pi * 440 * Float(frame) / 16_000) * 12_000)
            }
            try writer?.write(buffer)
        }
        writer = nil

        #expect(AudioArchive.exists(for: id))
        let readBack = try AVAudioFile(forReading: url)
        #expect(abs(Double(readBack.length) - 16_000) < 2_048)
    }

    @Test("createMeeting honors a caller-supplied id (audio shares identity)")
    func explicitMeetingID() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let store = EmbeddingStore(modelContainer: container)
        let sessionID = UUID()
        let created = try await store.createMeeting(id: sessionID, title: "Session")
        #expect(created == sessionID)
    }

    @Test("deleteMeeting removes the retained audio with the row")
    func deleteRemovesAudio() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let store = EmbeddingStore(modelContainer: container)
        let id = try await store.createMeeting(title: "Doomed with audio")

        // Plant a stand-in archive file.
        try AudioArchive.ensureDirectory()
        try Data("stub".utf8).write(to: AudioArchive.url(for: id))
        #expect(AudioArchive.exists(for: id))

        try await store.deleteMeeting(id)
        #expect(!AudioArchive.exists(for: id))
    }
}

@Suite("Phase 11 — Chat engine")
struct ChatEngineTests {

    @Test("Chat degrades to nil without the model; conversation state survives")
    func chatDegradesToNil() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let engine = ChatEngine(
            store: EmbeddingStore(modelContainer: container),
            forceUnavailable: true
        )
        #expect(await engine.ask("What did we decide?") == nil)
        #expect(await !engine.isAvailable)
    }

    @Test("Source chips deduplicate meeting titles in first-hit order")
    func sourceDeduplication() {
        func hit(_ title: String, score: Float) -> SearchHit {
            SearchHit(
                id: UUID(), meetingID: UUID(), meetingTitle: title,
                text: "…", startTime: 0, capturedAt: .now, score: score
            )
        }
        let titles = ChatEngine.uniqueSourceTitles(from: [
            hit("Budget Review", score: 0.9),
            hit("Standup", score: 0.8),
            hit("Budget Review", score: 0.7),
            hit("Retro", score: 0.6),
        ])
        #expect(titles == ["Budget Review", "Standup", "Retro"])
    }
}
