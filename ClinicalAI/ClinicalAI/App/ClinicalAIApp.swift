// ClinicalAIApp.swift
// ClinicalAI — App Entry Point
//
// Responsibilities at launch:
//   1. Call Wearables.configure() so the MWDAT SDK is ready before any service is created.
//   2. Observe registrationStateStream() and show MetaAIRegistrationView when the app
//      is not yet registered with the Meta AI companion app (one-time physician setup).
//   3. Check whether an Anthropic API key is in the Keychain; show setup if not.
//   4. Wire the scene's onOpenURL callback back to Wearables so the deep-link callback
//      from the Meta AI app is delivered to the SDK to complete registration.
//
// Registration flow (one-time physician setup):
//   a. SDK emits .available from registrationStateStream() → MetaAIRegistrationView appears.
//   b. Physician taps "Set Up in Meta AI" → Wearables.shared.startRegistration() opens Meta AI.
//   c. Physician grants access in the Meta AI app and taps "Done".
//   d. Meta AI deep-links back via clinicalai:// → onOpenURL fires.
//   e. Wearables.shared.handleUrl(_:) processes the callback.
//   f. SDK emits .registered → registration sheet dismisses automatically.
//   g. On the next startDiscovery(), the glasses appear in devicesStream().
//
// RegistrationState cases (from MWDATCore swiftinterface):
//   .unavailable  — cannot register right now (Meta AI not installed, no internet)
//   .available    — not yet registered, ready to start
//   .registering  — handshake in progress (Meta AI app open, waiting for callback)
//   .registered   — setup complete; glasses can be discovered and connected

import MWDATCore
import SwiftUI

@main
struct ClinicalAIApp: App {

    /// Tracks the current MWDAT registration state.
    /// Starts nil (stream not yet emitted); the .task below fills it on first emission.
    @State private var registrationState: RegistrationState? = nil

    /// Sheet is visible while registration is needed (.available) or in-flight (.registering).
    /// Dismissed automatically when the stream emits .registered.
    private var showRegistration: Bool {
        switch registrationState {
        case .some(.available), .some(.registering): return true
        default:                                     return false
        }
    }

    /// `true` when no API key is stored in the Keychain yet.
    @State private var showAPIKeySetup: Bool = !KeychainService.shared.hasAPIKey()

    init() {
        // MWDAT must be configured once before any other SDK call.
        // If configuration fails (e.g., the Info.plist MWDAT dict is incomplete),
        // glasses features will be unavailable but the rest of the app still works.
        do {
            try Wearables.configure()
        } catch {
            // Developer error: verify Info.plist has the correct MWDAT dict with
            // MetaAppID, ClientToken, TeamID, AppLinkURLScheme, and DAMEnabled = true.
            print("ClinicalAI ⚠️ Meta Wearables SDK configuration failed: \(error)")
            print("ClinicalAI ⚠️ Glasses features will be unavailable. Check Info.plist MWDAT dict.")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // ── Meta AI registration gate ─────────────────────────────────────
                // Shown on first launch (or if the physician unregistered).
                // Non-dismissible: the physician must complete setup to use the glasses.
                .sheet(isPresented: .constant(showRegistration)) {
                    MetaAIRegistrationView(isRegistering: registrationState == .registering) {
                        Task {
                            do {
                                try await Wearables.shared.startRegistration()
                            } catch {
                                print("ClinicalAI: startRegistration failed: \(error)")
                            }
                        }
                    }
                }
                // ── API key gate ──────────────────────────────────────────────────
                .sheet(isPresented: $showAPIKeySetup) {
                    APIKeySetupView {
                        showAPIKeySetup = false
                    }
                }
                // ── MWDAT deep-link handler ───────────────────────────────────────
                // The Meta AI app calls back to clinicalai:// after the physician
                // completes the registration flow. Forward the URL to the SDK.
                .onOpenURL { url in
                    Task {
                        do {
                            _ = try await Wearables.shared.handleUrl(url)
                        } catch {
                            // handleUrl can fail if the URL scheme is unrecognised or
                            // the registration was cancelled. Log and continue.
                            print("ClinicalAI: Wearables.handleUrl failed for \(url): \(error)")
                        }
                    }
                }
                // ── Registration state observation ────────────────────────────────
                // The stream emits the current state immediately on subscription, then
                // on every change. Storing it in @State drives showRegistration above.
                .task {
                    for await state in Wearables.shared.registrationStateStream() {
                        registrationState = state
                    }
                }
        }
    }
}

// MARK: - MetaAIRegistrationView

/// One-time setup sheet shown when the app is not yet registered with Meta AI.
///
/// The physician taps "Set Up in Meta AI" → Wearables.shared.startRegistration()
/// opens the Meta AI app. The physician approves there, Meta AI calls back via
/// clinicalai://, the SDK processes the URL, and emits .registered — at which
/// point ClinicalAIApp.showRegistration becomes false and the sheet dismisses.
private struct MetaAIRegistrationView: View {

    /// True while the SDK handshake is in progress (state == .registering).
    let isRegistering: Bool
    let onRegister: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()

                Image(systemName: "eyeglasses")
                    .font(.system(size: 72, weight: .thin))
                    .foregroundStyle(.secondary)

                VStack(spacing: 8) {
                    Text("Connect Your Glasses")
                        .font(.title2.weight(.semibold))

                    Text("ClinicalAI needs to register with the Meta AI app before it can connect to your Ray-Ban Meta glasses. This one-time setup takes about 30 seconds.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }

                Spacer()

                // While the handshake is in flight show a spinner instead of the
                // button so the physician knows to switch to the Meta AI app.
                if isRegistering {
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.3)
                        Text("Waiting for Meta AI…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 32)
                } else {
                    Button(action: onRegister) {
                        Label("Set Up in Meta AI", systemImage: "arrow.up.right.square")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
                }
            }
            .padding(.horizontal, 16)
            .navigationTitle("Glasses Setup")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled()
    }
}
