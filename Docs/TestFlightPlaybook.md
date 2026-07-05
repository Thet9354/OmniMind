# TestFlight Pilot Playbook

The steps that require the App Store Connect UI (they cannot be automated
from the repo). Work top to bottom; each is a one-time setup.

## 1. App Store Connect record

1. appstoreconnect.apple.com → My Apps → **+** → New App.
2. Platform iOS · Name **OmniMind** · Bundle ID `com.thetpine.workspace.OmniMind` · SKU e.g. `omnimind-001`.
3. Privacy Policy URL: required even for TestFlight external testing — a
   simple hosted page stating the app collects nothing works (GitHub Pages
   is fine).

## 2. Privacy nutrition labels (App Privacy section)

Select **"Data Not Collected."** That is the truthful answer for the whole
app: no analytics, no identifiers, no server. The bundled
`PrivacyInfo.xcprivacy` already matches this declaration.

## 3. Upload a build

1. Xcode: bump build number if re-uploading (target → General → Build).
2. Select **Any iOS Device (arm64)** → Product → **Archive**.
3. Organizer → Distribute App → App Store Connect → Upload.
   - Export compliance is pre-answered (`ITSAppUsesNonExemptEncryption = NO`).
4. Wait for processing (~10 min), then the build appears under TestFlight.

## 4. Testers

- **Internal testing** (up to 100 App Store Connect users, no review):
  add yourself + close testers → instant distribution.
- **External testing** (up to 10,000, requires one-time Beta App Review):
  create a group, add tester emails or enable a public link.
  - Beta review notes: see `Docs/AppReviewNotes.md` — paste the demo
    script there into the review notes field.

## 5. Pilot tester instructions (paste into the TestFlight "What to Test")

- Put the phone in the middle of the table, screen up, for best capture.
- Speak normally; the grey text is live guessing, black text is saved.
- After a meeting: try Search (search by meaning, not keywords),
  Generate Summary, and Clean Up Transcript.
- Known limitation: heavy accents, mumbling, and distant/fast speech
  reduce raw transcription accuracy — Clean Up Transcript usually helps.
- Send feedback with the ✉️ button in the app (prefills your app/OS
  versions) or via TestFlight's screenshot feedback.

## 6. Before flipping monetization back on (post-pilot)

1. Set `ProductCatalog.pilotUnlockEverything = false`.
2. Create the two subscriptions in App Store Connect exactly as in
   `OmniMindTests/OmniMind.storekit` (group "OmniMind Pro", monthly 4.99,
   annual 39.99) — product IDs must match `ProductCatalog` verbatim.
3. Re-run the StoreKit test suite; the paywall and gates re-arm on their own.
