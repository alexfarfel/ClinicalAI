// DiagnosticView.swift
// ClinicalAI — AI Diagnostic Partner Chat (Phase 2)
//
// A conversational chat interface the physician can open mid-encounter to consult
// the AI on differential diagnoses, suggested workup, or drug interactions.
// The AI has context from the current encounter transcript and any captured findings.
//
// Think of this as a "second opinion" chat window — the physician types a question
// (e.g., "What other diagnoses should I consider?") and Claude responds with
// evidence-based suggestions drawn from the encounter context.
//
// Binds to DiagnosticViewModel. Phase 2 feature — not active in Phase 1.

import SwiftUI

struct DiagnosticView: View {
    // TODO: Inject DiagnosticViewModel
    var body: some View {
        // TODO: Implement chat message list and text input
        Text("Diagnostic")
    }
}

#Preview {
    DiagnosticView()
}
