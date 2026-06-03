// APIKeySetupView.swift
// ClinicalAI — First-Run API Key Setup Screen
//
// Shown automatically on the first launch (or any launch where no API key is stored
// in the Keychain). The physician enters their Anthropic API key here; it is saved
// directly to the Keychain and never stored anywhere else.
//
// Why this screen exists:
//   The app calls the Anthropic Claude API to generate clinical notes. That API
//   requires a secret key that identifies and bills your Anthropic account.
//   The key must be supplied by the physician/administrator at setup time — it
//   cannot be embedded in the app itself (that would expose it to anyone who
//   decompiled the app binary).
//
// How to get your API key:
//   1. Visit https://console.anthropic.com
//   2. Sign in to your Anthropic account (or create one).
//   3. Navigate to "API Keys" in the left sidebar.
//   4. Click "Create Key", give it a name like "ClinicalAI iOS", and copy the value.
//      You will only see the full key once — copy it before closing that page.

import SwiftUI

// MARK: - APIKeySetupView

/// The first-run modal sheet that collects the Anthropic API key.
///
/// This view is non-dismissible until a valid key is saved, preventing the app from
/// being used in a state where note generation would immediately fail. The physician
/// can paste their key from the Anthropic console into the secure field.
struct APIKeySetupView: View {

    /// Called by the parent (ClinicalAIApp) after the key is successfully saved,
    /// so it can dismiss the sheet and allow the main UI to appear.
    let onCompletion: () -> Void

    // ── View state ────────────────────────────────────────────────────────────────
    @State private var apiKey: String = ""
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""
    @State private var isSaving: Bool = false

    /// The Save button is enabled only when the field is non-empty.
    private var canSave: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {

                // ── Key entry ─────────────────────────────────────────────────────
                Section {
                    SecureField("sk-ant-api03-…", text: $apiKey)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        // Monospaced font makes long key strings easier to verify visually.
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("Anthropic API Key")
                } footer: {
                    Text("""
                        Your key is stored in the iOS Keychain — encrypted by the OS and \
                        protected by your device passcode. It is only ever sent directly to \
                        Anthropic's API servers over a secure HTTPS connection.
                        """)
                }

                // ── How to get a key ─────────────────────────────────────────────
                Section {
                    instructionRow(number: "1", text: "Visit console.anthropic.com and sign in")
                    instructionRow(number: "2", text: "Open \"API Keys\" in the left sidebar")
                    instructionRow(number: "3", text: "Tap \"Create Key\" and name it \"ClinicalAI\"")
                    instructionRow(number: "4", text: "Copy the key and paste it in the field above")
                    instructionRow(number: "⚠︎", text: "You will only see the full key once — copy it before closing the page")
                } header: {
                    Text("How to get your key")
                }

                // ── Security note ─────────────────────────────────────────────────
                Section {
                    Label {
                        Text("The app will never transmit your key to any server except Anthropic's API.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "lock.shield.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("API Key Setup")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: saveKey) {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Save")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(!canSave)
                }
            }
            // Block interactive swipe-to-dismiss — the app needs the key to function.
            .interactiveDismissDisabled()
            .alert("Could Not Save Key", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    // MARK: - Private helpers

    /// Saves the trimmed key to the Keychain and calls `onCompletion` on success.
    private func saveKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSaving = true
        do {
            try KeychainService.shared.saveAPIKey(trimmed)
            onCompletion()
        } catch {
            isSaving = false
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    /// A numbered instruction row used in the "How to get your key" section.
    @ViewBuilder
    private func instructionRow(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.footnote.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
            Text(text)
                .font(.footnote)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Preview

#Preview("First Run") {
    APIKeySetupView(onCompletion: {})
}
