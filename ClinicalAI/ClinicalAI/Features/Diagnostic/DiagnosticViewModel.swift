// DiagnosticViewModel.swift
// ClinicalAI — AI Diagnostic Partner Business Logic (Phase 2)
//
// Drives DiagnosticView. Manages a real-time consultation chat between the physician
// and Claude during (or immediately after) a patient encounter.
//
// Responsibilities:
//   • Holds the full conversation history (in-memory only — never persisted to disk)
//   • Builds an opening auto-message that summarises the encounter context so the
//     physician immediately sees what the AI knows about the patient
//   • Streams Claude's responses token-by-token into streamingText, giving the
//     physician live feedback as the answer builds
//   • Moves the completed response into the messages array once streaming finishes
//
// Privacy rule: all DiagnosticChatMessage instances must be discarded when the
// encounter ends. This chat is a clinical thinking aid, not a medical record.
//
// @MainActor is intentionally absent — see CLAUDE.md concurrency rules.

import Foundation

// MARK: - DiagnosticChatMessage

/// A single turn in the AI consultation chat.
///
/// Role is either "user" (physician) or "assistant" (Claude).
/// `content` is the full text of the turn; for streaming turns use
/// `DiagnosticViewModel.streamingText` while the response is building.
struct DiagnosticChatMessage: Identifiable {
    let id: UUID
    let role: String       // "user" or "assistant"
    let content: String
    let timestamp: Date

    init(role: String, content: String) {
        self.id        = UUID()
        self.role      = role
        self.content   = content
        self.timestamp = Date()
    }
}

// MARK: - DiagnosticViewModel

@Observable
final class DiagnosticViewModel {

    // MARK: - Dependencies

    /// The encounter session providing patient context for every API call.
    private let session: EncounterSession

    /// The AI service used for streaming diagnostic consultations.
    private let llmService: any LLMServiceProtocol

    // MARK: - State

    /// The full conversation history in chronological order.
    ///
    /// The first entry is always the opening auto-message generated at init time.
    /// User turns have role "user"; Claude turns have role "assistant".
    var messages: [DiagnosticChatMessage] = []

    /// True while a streaming call is in flight.
    ///
    /// The View disables the send button and shows a typing indicator based on this flag.
    var isThinking = false

    /// Accumulates streaming tokens from Claude as they arrive.
    ///
    /// Rendered as a live "in-progress" bubble in the chat list. Cleared and moved into
    /// `messages` once the stream completes.
    var streamingText = ""

    /// Non-nil when the most recent consultation call fails.
    /// Displayed as an alert so the physician can retry.
    var errorMessage: String?

    // MARK: - Init

    /// Creates the ViewModel for the given encounter session.
    ///
    /// An opening message is generated immediately from the session data (no API call).
    /// The message summarises the transcript and exam findings so the physician can see
    /// what patient context Claude will have for every question they ask.
    ///
    /// - Parameters:
    ///   - session:    The EncounterSession currently in progress. Passed to every API call
    ///                 so Claude always has the full patient context.
    ///   - llmService: Injected AI service. Defaults to MockLLMService for Xcode Previews
    ///                 and development without a live API key.
    init(
        session: EncounterSession,
        llmService: any LLMServiceProtocol = MockLLMService()
    ) {
        self.session    = session
        self.llmService = llmService

        // Seed the conversation with a locally-generated encounter summary.
        // No API call is needed here — the summary is assembled from the session struct.
        messages = [DiagnosticChatMessage(
            role: "assistant",
            content: buildOpeningMessage(for: session)
        )]
    }

    // MARK: - Actions

    /// Sends a physician question to Claude and streams the response into `streamingText`.
    ///
    /// Call flow:
    ///   1. The user's message is appended to `messages` immediately.
    ///   2. `isThinking` is set to true — the UI shows a typing indicator.
    ///   3. Tokens are appended to `streamingText` as they arrive from the stream.
    ///   4. When the stream completes, `streamingText` is moved into `messages` as an
    ///      "assistant" turn, then cleared. `isThinking` is set back to false.
    ///   5. On error, `errorMessage` is set for the View's alert.
    ///
    /// Guard ensures a second message cannot be sent while the first is streaming.
    func sendMessage(text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isThinking else { return }

        messages.append(DiagnosticChatMessage(role: "user", content: trimmed))
        isThinking    = true
        streamingText = ""

        do {
            // Every call receives the full EncounterSession so Claude has the patient
            // context (transcript, exam findings) prepended to the system prompt.
            let stream = llmService.streamDiagnosticConsultation(
                for: session,
                question: trimmed
            )
            for try await token in stream {
                streamingText += token
            }

            // Stream complete — move the response into the permanent history.
            // Setting streamingText = "" before isThinking = false avoids a brief
            // flash where an empty typing indicator would appear between the two updates.
            let completed = streamingText
            streamingText = ""
            isThinking    = false
            messages.append(DiagnosticChatMessage(role: "assistant", content: completed))

        } catch {
            streamingText = ""
            isThinking    = false
            errorMessage  = "Consultation failed: \(error.localizedDescription)"
        }
    }

    /// Clears the current error message (called after the alert is dismissed).
    func clearError() {
        errorMessage = nil
    }

    // MARK: - Private helpers

    /// Builds the opening auto-message from the session's transcript and exam findings.
    ///
    /// This message is displayed as the first "assistant" bubble when DiagnosticView opens.
    /// It gives the physician immediate visibility into what patient data Claude will
    /// use when answering questions, and ends with a starter diagnostic question.
    ///
    /// No API call is made — the summary is constructed entirely from the session struct.
    private func buildOpeningMessage(for session: EncounterSession) -> String {
        var parts: [String] = []

        // --- Encounter context header ---
        if let duration = session.durationSeconds {
            let mins = Int(duration) / 60
            let secs = Int(duration) % 60
            parts.append("Encounter duration: \(mins)m \(secs)s")
        } else {
            parts.append("Encounter is in progress.")
        }

        // --- Transcript summary ---
        let transcript = session.fullTranscript
        if transcript.isEmpty {
            parts.append("Audio transcript: No audio has been captured yet for this encounter.")
        } else {
            // Truncate at 300 characters to keep the opening message readable.
            let preview = transcript.count > 300
                ? String(transcript.prefix(300)) + "…"
                : transcript
            parts.append("Transcript excerpt: \(preview)")
        }

        // --- Physical exam findings ---
        if session.examFindings.isEmpty {
            parts.append("Physical exam findings: None captured yet.")
        } else {
            let list = session.examFindings
                .map { "• \($0.bodySystem.displayName): \($0.annotation.isEmpty ? "(finding captured, no annotation)" : $0.annotation)" }
                .joined(separator: "\n")
            parts.append("Physical exam findings:\n\(list)")
        }

        // --- Opening question ---
        parts.append("Based on this presentation, what are your primary diagnostic considerations?")

        return parts.joined(separator: "\n\n")
    }
}
