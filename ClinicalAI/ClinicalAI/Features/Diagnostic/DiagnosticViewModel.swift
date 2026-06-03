// DiagnosticViewModel.swift
// ClinicalAI — Diagnostic Partner Business Logic (Phase 2)
//
// Drives the DiagnosticView. Manages the real-time consultation chat:
//   - Maintains the conversation history (array of DiagnosticSuggestion)
//   - Sends physician questions to LLMService along with encounter context
//   - Streams Claude's response tokens into the UI as they arrive
//   - Does NOT persist the chat — this is an in-session consultation only
//
// Uses @Observable. All network calls use async/await with streaming support.

import Foundation

@Observable
final class DiagnosticViewModel {
    // TODO: Inject LLMService protocol via initializer

    // TODO: Published state — messages: [DiagnosticSuggestion], isStreaming, etc.
}
