# App Review Notes (paste into Review Notes / Beta Review Notes)

## What the app does

OmniMind records meetings and transcribes them live, entirely on-device,
using Apple's Speech framework (SpeechAnalyzer). Users can search their
meeting history semantically and generate AI summaries — all processing
uses Apple's on-device frameworks (NaturalLanguage, FoundationModels).
No audio or text ever leaves the device; the app has no server.

## Permission justifications

- **Microphone (NSMicrophoneUsageDescription):** core function — live
  meeting capture. Requested only when the user starts their first
  recording, never at launch.
- **Speech recognition (NSSpeechRecognitionUsageDescription):** converts
  the captured audio to text using on-device recognition. No audio is
  sent to Apple servers by the app (on-device SpeechAnalyzer models).
- **Background audio (UIBackgroundModes: audio):** meetings routinely
  outlast the screen — capture must continue while the device is locked
  or the user switches apps mid-meeting. Recording only ever starts from
  an explicit user tap; iOS shows the system recording indicator the
  entire time. No playback, no audio is stored or transmitted.
- **Reminders (NSRemindersFullAccessUsageDescription):** the app can
  extract action items from a meeting (on-device) and, only when the
  user taps "Add All to Reminders", write them to the default Reminders
  list. Access is requested at that moment, never at launch. Nothing is
  read back beyond what EventKit requires to save.

## Demo script for review

1. Launch → tap the record button (top right) → "Record".
2. Grant microphone permission when prompted.
3. Speak a few sentences — live transcription appears (grey → black).
4. Tap Stop → Done → the meeting appears in the list.
5. Open the meeting → "Generate Summary" (requires Apple Intelligence-
   capable hardware; on other devices a key-excerpts summary appears).
6. Magnifying-glass icon → search by meaning (e.g. "budget" finds
   money-related discussion phrased differently).

No account, no login, no network dependency after the one-time on-device
model downloads (managed by the OS).

## Groups (iCloud/CloudKit)

Users can optionally create "groups" (a team, class, or project) and
publish individual meetings to them. A group is a CloudKit record zone
in the group owner's personal iCloud, shared via the system
collaboration sheet (zone-wide CKShare). Key facts:

- Publishing is always an explicit per-meeting user action — nothing
  syncs automatically, and recording/transcription remain fully
  on-device.
- The developer operates no server and cannot access group content;
  data lives only in the members' iCloud accounts (private/shared
  CloudKit database).
- Without an iCloud account the feature shows a sign-in prompt and the
  rest of the app is unaffected.

## In-app purchases

A StoreKit 2 subscription subsystem exists in the binary but is dormant:
during the pilot, all features are free and no paywall is reachable. No
products are configured in App Store Connect yet.
