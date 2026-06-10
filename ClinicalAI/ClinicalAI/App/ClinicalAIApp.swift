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
//   d. Meta AI deep-links back via farfelmed.ClinicalAI:// → onOpenURL fires.
//   e. Wearables.shared.handleUrl(_:) processes the callback.
//   f. SDK emits .registered → registration sheet dismisses automatically.
//   g. On the next startDiscovery(), the glasses appear in devicesStream().
//
// Reset flow (if registration appears stuck):
//   Tap "Force Re-register" → startUnregistration() then startRegistration().
//   This clears any cached credential state on the SDK side and re-opens Meta AI.
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
        // Production config is read from Info.plist MWDAT dict:
        //   MetaAppID      = $(META_APP_ID)   from Secrets.xcconfig
        //   ClientToken    = $(CLIENT_TOKEN)   from Secrets.xcconfig
        //   TeamID         = $(DEVELOPMENT_TEAM)  = F74TQ3S46Y
        //   AppLinkURLScheme = https://alexfarfel.github.io/ClinicalAI/
        //   DAMEnabled     = true
        do {
            try Wearables.configure()
            print("ClinicalAI ✅ Wearables.configure() succeeded")
        } catch {
            print("ClinicalAI ⚠️ Wearables.configure() failed: \(error)")
            print("ClinicalAI ⚠️ Check Info.plist MWDAT dict and Secrets.xcconfig values.")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // ── Meta AI registration gate ─────────────────────────────────────
                .sheet(isPresented: .constant(showRegistration)) {
                    MetaAIRegistrationView(
                        isRegistering: registrationState == .registering,
                        onRegister: {
                            print("ClinicalAI 🔑 'Set Up in Meta AI' tapped — registrationState = \(String(describing: registrationState))")
                            Task {
                                do {
                                    print("ClinicalAI 🔑 Calling startRegistration()…")
                                    try await Wearables.shared.startRegistration()
                                    print("ClinicalAI 🔑 startRegistration() returned without error")
                                } catch {
                                    print("ClinicalAI 🔑 startRegistration() failed: \(error)")
                                }
                            }
                        },
                        onReset: {
                            print("ClinicalAI 🔑 'Force Re-register' tapped — registrationState = \(String(describing: registrationState))")
                            Task {
                                do {
                                    print("ClinicalAI 🔑 Calling startUnregistration()…")
                                    try await Wearables.shared.startUnregistration()
                                    print("ClinicalAI 🔑 startUnregistration() complete — calling startRegistration()…")
                                    try await Wearables.shared.startRegistration()
                                    print("ClinicalAI 🔑 startRegistration() returned without error after reset")
                                } catch {
                                    print("ClinicalAI 🔑 reset flow failed: \(error)")
                                }
                            }
                        }
                    )
                }
                // ── API key gate ──────────────────────────────────────────────────
                .sheet(isPresented: $showAPIKeySetup) {
                    APIKeySetupView {
                        showAPIKeySetup = false
                    }
                }
                // ── MWDAT deep-link handler ───────────────────────────────────────
                // Meta AI calls back via the farfelmed.ClinicalAI:// scheme after the
                // physician completes the registration flow. Forward to the SDK.
                .onOpenURL { url in
                    print("ClinicalAI 🔗 onOpenURL: \(url)")
                    Task {
                        do {
                            let handled = try await Wearables.shared.handleUrl(url)
                            print("ClinicalAI 🔗 handleUrl returned: \(handled)")
                        } catch {
                            print("ClinicalAI 🔗 handleUrl failed for \(url): \(error)")
                        }
                    }
                }
                // ── Registration state observation ────────────────────────────────
                // The stream emits the current state immediately on subscription,
                // then on every change. Each emission is logged for debugging.
                .task {
                    for await state in Wearables.shared.registrationStateStream() {
                        print("ClinicalAI 🔑 registrationState → \(state)")
                        registrationState = state
                    }
                }
        }
    }
}

// MARK: - MetaAIRegistrationView

/// One-time setup sheet shown when the app is not yet registered with Meta AI.
///
/// Normal flow: tap "Set Up in Meta AI" → completes in Meta AI app → sheet auto-dismisses.
/// Reset flow:  tap "Force Re-register" → clears cached state → re-opens Meta AI.
private struct MetaAIRegistrationView: View {

    /// True while the SDK handshake is in progress (state == .registering).
    let isRegistering: Bool
    let onRegister: () -> Void
    let onReset: () -> Void

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

                // While the handshake is in flight show a spinner so the
                // physician knows to switch to the Meta AI app.
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
                    VStack(spacing: 12) {
                        Button(action: onRegister) {
                            Label("Set Up in Meta AI", systemImage: "arrow.up.right.square")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .padding(.horizontal, 24)

                        // Reset clears any stale cached registration on the SDK side
                        // and forces a fresh trip through the Meta AI permission dialog.
                        Button(action: onReset) {
                            Text("Force Re-register")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 32)
                    }
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
