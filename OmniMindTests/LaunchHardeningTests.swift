//
//  LaunchHardeningTests.swift
//  OmniMindTests
//
//  Phase 8 verification: release-readiness artifacts that must ship inside
//  the app bundle, checked from the test host (which IS the app bundle).
//

import Foundation
import Testing

@Suite("Phase 8 — Launch hardening")
struct LaunchHardeningTests {

    @Test("Privacy manifest ships in the app bundle and declares no data collection")
    func privacyManifestBundled() throws {
        let url = try #require(
            Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
            "PrivacyInfo.xcprivacy missing from the app bundle"
        )
        let data = try Data(contentsOf: url)
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )
        #expect(plist["NSPrivacyTracking"] as? Bool == false)
        #expect((plist["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty == true)
        #expect((plist["NSPrivacyTrackingDomains"] as? [Any])?.isEmpty == true)
    }

    @Test("Export compliance is pre-declared (no non-exempt encryption)")
    func exportComplianceDeclared() {
        let value = Bundle.main.infoDictionary?["ITSAppUsesNonExemptEncryption"] as? Bool
        #expect(value == false)
    }

    @Test("Usage descriptions ship with the privacy-forward copy")
    func usageDescriptionsPresent() {
        let info = Bundle.main.infoDictionary
        let mic = info?["NSMicrophoneUsageDescription"] as? String ?? ""
        let speech = info?["NSSpeechRecognitionUsageDescription"] as? String ?? ""
        let reminders = info?["NSRemindersFullAccessUsageDescription"] as? String ?? ""
        #expect(mic.contains("on this device"))
        #expect(speech.contains("on-device"))
        #expect(reminders.contains("only when you ask"))
    }

    @Test("Background audio mode is declared — capture survives lock/app-switch")
    func backgroundAudioDeclared() {
        let modes = Bundle.main.infoDictionary?["UIBackgroundModes"] as? [String] ?? []
        #expect(modes.contains("audio"))
    }
}
