// ClinicalAIApp.swift
// ClinicalAI — App Entry Point
//
// Responsibilities at launch:
//   1. Call Wearables.configure() so the MWDAT SDK is ready before any service is created.
//   2. Check whether an Anthropic API key is in the Keychain; show setup if not.
//   3. Wire the scene's onOpenURL callback back to Wearables so deep-link registration
//      callbacks from the Meta AI app are handled correctly.
//
// Registration flow (one-time physician setup):
//   a. Physician opens ClinicalAI for the first time.
//   b. GlassesService.startRegistration() is called, which opens the Meta AI app.
//   c. Physician completes pairing in the Meta AI app and taps "Done".
//   d. Meta AI app deep-links back to ClinicalAI via clinicalai://
//   e. onOpenURL fires → Wearables.shared.handleUrl(_:) processes the callback.
//   f. On the next startDiscovery(), the paired glasses appear in devicesStream().

import MWDATCore
import SwiftUI

@main
struct ClinicalAIApp: App {

    /// `true` when no API key is stored in the Keychain yet.
    @State private var showAPIKeySetup: Bool = !KeychainService.shared.hasAPIKey()

    init() {
        // MWDAT must be configured once before any other SDK call.
        // If configuration fails (e.g., the Info.plist MWDAT dict is incomplete),
        // glasses features will be unavailable but the rest of the app still works.
        do {
            try Wearables.configure()
        } catch {
            // This is a developer error: verify that Info.plist contains the correct
            // MWDAT dict with MetaAppID, ClientToken, TeamID, AppLinkURLScheme, and
            // DAMEnabled = true. See Info.plist in the project for the full structure.
            print("ClinicalAI ⚠️ Meta Wearables SDK configuration failed: \(error)")
            print("ClinicalAI ⚠️ Glasses features will be unavailable. Check Info.plist MWDAT dict.")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // ── API key gate ──────────────────────────────────────────────────
                .sheet(isPresented: $showAPIKeySetup) {
                    APIKeySetupView {
                        showAPIKeySetup = false
                    }
                }
                // ── MWDAT deep-link handler ───────────────────────────────────────
                // The Meta AI app calls back to clinicalai:// after the physician
                // completes the glasses registration (pairing) flow. We must forward
                // that URL to the SDK so it can complete the handshake.
                .onOpenURL { url in
                    Task {
                        do {
                            _ = try await Wearables.shared.handleUrl(url)
                        } catch {
                            // handleUrl(_:) can fail if the URL scheme is unrecognised
                            // or the registration was cancelled. Log and ignore.
                            print("ClinicalAI: Wearables.handleUrl failed for \(url): \(error)")
                        }
                    }
                }
        }
    }
}
