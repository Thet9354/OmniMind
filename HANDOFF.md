# OmniMind — Session Handoff

Last updated: 2026-07-06 · Head commit: `9944308` · Branch: `main` · All work pushed to `https://github.com/Thet9354/OmniMind.git`.

This file is the single source of truth for picking up development. Read it first.

---

## What OmniMind is

A **local-first, on-device meeting intelligence app** for iOS 26. Live transcription → coalesced transcripts → semantic search + multi-turn chat over history → AI summaries, action items, transcript cleanup → replayable audio. Everything runs on-device (Speech, NaturalLanguage, FoundationModels); nothing touches a server. Built as both a commercial pilot app and a portfolio flagship.

- **Stack:** Swift 6 (strict concurrency, `complete`) · SwiftUI · SwiftData (versioned schema + migration plan) · AVAudioEngine · Speech (`SpeechAnalyzer`) · NaturalLanguage (`NLContextualEmbedding`) · Accelerate (vDSP) · FoundationModels · StoreKit 2 · EventKit · Swift Testing.
- **Deployment target:** iOS 26.0. **Bundle id:** `com.thetpine.workspace.OmniMind`. **Team:** `K8FKWBYV9S`.

## CRITICAL environment facts (do not relearn these the hard way)

1. **Run tests on the iOS 26.1 simulator, NOT 26.5.** storekitd's testing mode is broken in the 26.5 simulator runtime (`SKInternalErrorDomain Code=3`, products never resolve). Known-good device: **iPhone 17 Pro, iOS 26.1, id `DA901926-604B-4A95-B379-7980C1909E9B`**.
   - Test command: `xcodebuild -project OmniMind.xcodeproj -scheme OmniMind -destination 'platform=iOS Simulator,id=DA901926-604B-4A95-B379-7980C1909E9B' -only-testing:OmniMindTests test`
2. **Swift Testing `-only-testing:` pointed at a FUNCTION silently matches nothing** and reports a vacuous "TEST SUCCEEDED". Always filter at suite level and confirm the `✔ Test run with N tests` line.
3. **FoundationModels / NLContextualEmbedding / SpeechTranscriber assets are unavailable in the simulator** — the tests that need them auto-SKIP there and must be verified on a physical device. `SystemLanguageModel.default.availability` reads `.available` on simulators even when inference is sandbox-denied, so FM tests gate on a real probe `respond()` call.
4. **`UIBackgroundModes` is NOT a valid `INFOPLIST_KEY_` build setting.** It lives in `Config/Info.plist` (a partial plist merged with the generated one via `INFOPLIST_FILE = Config/Info.plist` while `GENERATE_INFOPLIST_FILE` stays YES).
5. **`AVAudioFile` finalizes its header on deallocation** — release an `AudioArchiveWriter` before reading the file back.
   - **And its processing format must match every buffer passed to `write(from:)`** — a mismatch is a CoreAudio assert that ABORTS the process (not a thrown error). The settings-only `AVAudioFile(forWriting:settings:)` initializer defaults to Float32 deinterleaved, but on hardware `SpeechAnalyzer.bestAvailableAudioFormat` is Int16 — this crashed the first on-device Record tap (fixed by pinning `commonFormat:`/`interleaved:` to the incoming stream; simulator tests can't catch it unless they write Int16 buffers, which the regression test now does).
6. Files under `OmniMind/` auto-join the app target (`PBXFileSystemSynchronizedRootGroup`) — no pbxproj surgery to add a source file. The same is true for `OmniMindTests/`.

## Verification baseline (current)

- **74 tests / 18 suites green** on the iOS 26.1 simulator (5 hardware-gated tests skip there, run on device).
- **Release configuration builds clean** (`-configuration Release -destination 'generic/platform=iOS Simulator' build`).

## Architecture (subsystems, each behind a Swift 6 isolation boundary)

Cross-boundary traffic is always `Sendable` DTOs — never live `@Model` objects, audio buffers, or attributed strings.

- **Capture** (`OmniMind/Capture/`): RT audio tap → `AudioBufferBridge` (lock-free, bounded drop-oldest + atomic shed counter, `@unchecked Sendable` with documented linear-transfer invariant) → `AudioBufferStream` (Sendable). `AudioStreamActor` owns the engine, session (`.default` mode for far-field AGC), interruption/route-change handling. `AudioFormatConverter` (stateful SRC + `flush()`). `AudioLevel` (RMS→dBFS meter). `AudioArchive`/`AudioArchiveWriter` (optional AAC retention, named by meeting UUID). `FileAudioSource` (test double).
- **Transcription** (`OmniMind/Transcription/`): `TranscriptionActor` on `SpeechAnalyzer`/`SpeechTranscriber`; emits `TranscriptionUpdate` (`.volatile` / `.finalized` / `.audioLevel`). `SegmentCoalescer` merges micro-utterances into coherent chunks (word/duration/gap rules) BEFORE persistence.
- **Memory** (`OmniMind/Memory/`): `EmbeddingStore` (`@ModelActor`, the single persistence funnel — DTOs only across the boundary). `Embedder` (`NLContextualEmbedding`, mean-pool + L2-normalize). `VectorMath` (vDSP cosine + `TopKHeap`). `SchemaV1` (Meeting/Segment) + `OmniMindMigrationPlan` (V1 root; add a stage for any schema change). `SegmentPager` (windowed fetches). `SearchHit`/`EmbeddedSegment` DTOs.
- **Synthesis** (`OmniMind/Synthesis/`): `MeetingSynthesizer` actor (summaries, grounded Q&A, transcript cleanup, auto-titles, `@Generable` action items — every failure path falls back to extractive/nil). `ContextAssembler` (token-budgeted grounding). `ExtractiveSummarizer` (centroid fallback). `ChatEngine` (multi-turn RAG, per-turn retrieval).
- **Store** (`OmniMind/Store/`): `EntitlementStore` (`@MainActor`, verified-only entitlements, lifetime `Transaction.updates` listener) + `ProductCatalog`. **Dormant during pilot** — see below.
- **Export** (`OmniMind/Export/`): `TranscriptExporter` (Markdown), `RemindersExporter` (EventKit, access on demand).
- **UI** (`OmniMind/UI/`): `ContentView` (list + toolbar), `RecordingView`/`RecordingViewModel`, `MeetingDetailView`, `SearchView`, `ChatView`, `PaywallView`, `OnboardingView`, `TailBuffer` (bounded live memory).

## Enforced invariants (do not break)

1. Audio render thread does exactly one thing: a lock-free enqueue. No allocation, locks, or actor hops.
2. Backpressure sheds oldest audio (counted, surfaced as a degraded-capture banner) — never blocks the RT thread.
3. All persistence flows through the one `@ModelActor`; vectors commit atomically with rows; missing ML assets degrade to unembedded rows that `backfillEmbeddings()` repairs.
4. Live UI memory is bounded by `TailBuffer` (newest 50); long transcripts render via `SegmentPager`.
5. Only finalized (coalesced) segments persist; volatile text is a single replaceable property.
6. Every AI failure path lands on a working fallback (extractive summary / raw transcript / nil).

## MONETIZATION IS DORMANT (pilot decision, do not re-gate)

The app is **free for all features during the pilot**. Implemented via `ProductCatalog.pilotUnlockEverything = true` and `EntitlementStore.hasFullAccess`. The entire StoreKit 2 subsystem is built, wired, and tested underneath — flipping the flag to `false` re-arms every gate. **Do not add feature gating unless the user says the pilot is over.** Re-arm procedure is in `Docs/TestFlightPlaybook.md`.

## User's working style (IMPORTANT)

- **Vet-per-phase.** The user approves work in "phases/sprints"; **stop after each and wait for approval before starting the next.** They vet on-device at night in a batch.
- **Maintain a cumulative "Night Review Checklist."** At every phase stop, print a running checklist of concrete on-device steps to verify, accumulated across all phases since their last confirmed review. Reset it only when they say they've reviewed.
- **Commit + push each phase** to `origin/main` with a detailed message (they use the GitHub repo above). Commit messages in this repo end with a `Co-Authored-By: Claude ...` trailer.
- Run the full test suite and a Release build before declaring a phase done.

## Phase history (all on `main`, all pushed)

Phase 0 foundation → 1 capture graph → 2 transcription → 3 persistence → 4 embeddings/RAG search → 5 StoreKit → 6 synthesis → 7 resilience/polish → 7.5 transcription quality + free pilot → 8 launch hardening → app icon → 9 (Sprint A) latency/feel → 10 (Sprint B) background recording/auto-titles/action items → 11 (Tier 2) chat/audio replay/turn markers/onboarding.

## What's next (nothing in progress; awaiting user direction)

**User-side, not code:**
- Night-vet Sprints A + B + Tier 2 on device (checklists were provided in-session).
- **TestFlight upload** — follow `Docs/TestFlightPlaybook.md` (App Store Connect record, "Data Not Collected" nutrition label, archive+upload, tester groups). `Docs/AppReviewNotes.md` has the reviewer script + permission justifications.

**Deferred features (need the user at the keyboard / a product decision — do NOT start unprompted):**
- **Live Activity / Dynamic Island** while recording — requires a NEW widget-extension target. The user must create it via Xcode (File → New → Target → Widget Extension); then wire ActivityKit. Hand-editing a new target into project.pbxproj is risky — do it with the user present.
- **iCloud sync** (SwiftData + CloudKit) — changes the "nothing leaves the device" privacy story; a deliberate product decision, ideally after pilot feedback.

**Backlog ideas (brainstormed, unapproved):** multilingual capture (needs a multilingual embedding model swap), live translation, widgets/watch remote, speaker diarization (not in Apple's on-device stack — current pause-based markers are the honest approximation).

## Key docs in this repo

- `README.md` — portfolio-grade architecture overview.
- `Docs/TestFlightPlaybook.md` — the App Store Connect steps + pilot tester instructions + monetization re-arm.
- `Docs/AppReviewNotes.md` — permission justifications + reviewer demo script.
- `HANDOFF.md` — this file.
