# OmniMind

**A local-first, on-device meeting intelligence studio for iOS.** Live transcription, semantic search over everything you've ever captured, and AI summaries — with audio, transcripts, vectors, and generated text never leaving the device.

> Currently in free pilot: all features unlocked while gathering tester feedback.

## Architecture

Four subsystems, each isolated behind a Swift 6 strict-concurrency boundary. All cross-boundary traffic is `Sendable` DTOs — never live models, never audio buffers, never attributed strings.

```
┌──────────────┐  AVAudioPCMBuffer      ┌───────────────────┐
│ AVAudioEngine│ ────(render thread)──▶ │ AudioBufferBridge │  lock-free, bounded,
│  input tap   │  yield → continuation  │ (drop-oldest+count)│  drop-oldest queue
└──────────────┘                        └─────────┬─────────┘
                                    AudioBufferStream (Sendable)
                                                  │
                                        ┌─────────▼─────────┐
                                        │ TranscriptionActor│  SpeechAnalyzer +
                                        │  volatile / final │  SpeechTranscriber
                                        └─────────┬─────────┘  (iOS 26, on-device)
                                     TranscriptSegment (Sendable DTO)
                                                  │
                                        ┌─────────▼─────────┐
                                        │ SegmentCoalescer  │  micro-utterances →
                                        └─────────┬─────────┘  coherent chunks
                                                  │
                    ┌─────────────────────────────▼───────────────┐
                    │ EmbeddingStore (@ModelActor)                 │
                    │ NLContextualEmbedding → L2-normalized vector │
                    │ → SwiftData row (atomic with segment write)  │
                    │ search = vDSP cosine scan + bounded top-K    │
                    └─────────────────────────────┬───────────────┘
                                          SearchHit DTOs
                                                  │
                                        ┌─────────▼─────────┐
                                        │ MeetingSynthesizer│  FoundationModels
                                        │ summaries · Q&A · │  (LanguageModelSession)
                                        │ transcript repair │  + extractive fallback
                                        └───────────────────┘
```

| Subsystem | Isolation | Key files |
|---|---|---|
| Capture | RT thread → `AudioBufferBridge` (`@unchecked Sendable`, documented linear-transfer invariant) | `Capture/` |
| Transcription | `TranscriptionActor` | `Transcription/` |
| Semantic memory | `EmbeddingStore` (`@ModelActor`) | `Memory/` |
| Synthesis | `MeetingSynthesizer` actor | `Synthesis/` |
| Monetization (dormant during pilot) | `@MainActor EntitlementStore` + detached `Transaction.updates` listener | `Store/` |

### Enforced invariants

1. **The audio render thread does exactly one thing**: a lock-free enqueue. No allocation, no locks, no actor hops. Conversion happens downstream.
2. **Backpressure sheds oldest audio, never blocks the RT thread** — and every shed is counted and surfaced in the UI as a degraded-capture warning.
3. **All persistence flows through one `@ModelActor`**; vectors commit atomically with their rows; missing ML assets degrade to unembedded rows that a backfill pass repairs.
4. **Live UI memory is bounded by construction** (`TailBuffer`): a 3-hour meeting costs the live view the same memory as a 3-minute one. Long transcripts render through windowed fetches.
5. **Entitlements derive only from cryptographically verified transactions** (subsystem fully built and tested; gates opened by the pilot flag).
6. **Every AI failure path lands on a working fallback**: no model → extractive summaries; no assets → capture still persists; generation refused → raw transcript stands.

## Testing

58 tests across 15 suites (Swift Testing), including:

- DSP correctness: sample-rate conversion convergence, SRC-tail flush, bounded-bridge shed accounting
- A TTS-synthesized golden-audio pipeline gate (WER ≤ 0.15) requiring zero hardware
- 50k-vector semantic scan under 50 ms (Accelerate hot path)
- A six-stage StoreKit lifecycle over one `SKTestSession`
- Structural memory-bound proofs (3-hour synthetic session)

Environment-gated tests (speech/embedding/LLM assets) skip truthfully where the hardware can't run them — including a probe-generation gate, because availability flags lie on simulators.

**Run:** `⌘U` on an **iOS 26.1** simulator. (Known Apple issue: storekitd's testing mode is broken in the 26.5 simulator runtime.)

## Privacy

No tracking, no analytics, no server. The privacy manifest declares zero collected data types. Speech recognition, embedding generation, and language-model inference are all Apple on-device frameworks. Feedback is a plain prefilled email.

Sharing is opt-in and serverless: meeting bundles travel as files the user explicitly shares (AirDrop/share sheet), and group libraries live in the group owner's personal iCloud via CloudKit — storage the developer cannot read. Nothing leaves the device unless the user publishes it.

## Stack

Swift 6 (strict concurrency) · SwiftUI · SwiftData (versioned schema + migration plan) · AVAudioEngine · Speech (`SpeechAnalyzer`) · NaturalLanguage (`NLContextualEmbedding`) · Accelerate (vDSP) · FoundationModels · StoreKit 2 · Swift Testing
