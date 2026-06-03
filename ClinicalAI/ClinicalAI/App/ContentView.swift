// ContentView.swift
// ClinicalAI — Root Navigation Shell
//
// The first view the user sees after the API key setup screen completes.
// Currently routes directly to EncounterView.
//
// TODO: Replace with a TabView once Notes history and Phase 2 Diagnostic tabs are built:
//   Tab 1 — EncounterView  (start / manage encounters)
//   Tab 2 — Notes list     (review previously generated notes)
//   Tab 3 — DiagnosticView (Phase 2 AI diagnostic partner)
//
// TODO: Swap MockGlassesService / MockLLMService for real implementations once the
//       Meta Wearables SDK is integrated and the Anthropic API key is confirmed working.

import SwiftUI

struct ContentView: View {
    var body: some View {
        // EncounterView owns its ViewModel and defaults to mock services,
        // so the full UI is exercisable in the simulator without hardware.
        EncounterView()
    }
}

#Preview {
    ContentView()
}
