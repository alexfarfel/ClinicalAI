// DiagnosticView.swift
// ClinicalAI — AI Diagnostic Partner Chat (Phase 2)
//
// A clinical chat interface the physician opens mid-encounter (or immediately after)
// to consult Claude on differential diagnoses, workup, and decision-making.
//
// Layout:
//   ┌─────────────────────────────────────────┐
//   │  AI Diagnostic Partner            [nav]  │
//   ├─────────────────────────────────────────┤
//   │  ╭──────────────────────────────╮       │
//   │  │ Encounter summary... Based   │ ← AI  │
//   │  │ on this presentation, what   │       │
//   │  │ are your diagnostic consid…? │       │
//   │  ╰──────────────────────────────╯       │
//   │              ╭──────────────────────╮   │
//   │              │ What about pneumonia? │ ← │ physician
//   │              ╰──────────────────────╯   │
//   │  ╭────────────────────────────╮         │
//   │  │ Given the right lower lobe │ ← AI    │
//   │  │ crackles...                │         │
//   │  ╰────────────────────────────╯         │
//   │  ● ● ●  ← typing indicator             │
//   ├─────────────────────────────────────────┤
//   │ [What tests?] [Exam finding?] [More…]   │ ← chips
//   ├─────────────────────────────────────────┤
//   │  ┌──────────────────────────┐  [⬆]     │ ← input
//   │  │ Ask about this patient…  │           │
//   │  └──────────────────────────┘           │
//   └─────────────────────────────────────────┘
//
// Bubbles: white (with border) for physician · light blue for AI
// No decorative colours — clean, clinical aesthetic.

import SwiftUI
import UIKit

// MARK: - DiagnosticView

struct DiagnosticView: View {

    // ── ViewModel ──────────────────────────────────────────────────────────────
    @State private var viewModel: DiagnosticViewModel

    // ── View-only state ────────────────────────────────────────────────────────

    /// Text the physician is currently composing.
    @State private var inputText = ""

    // MARK: - Init

    init(session: EncounterSession) {
        _viewModel = State(wrappedValue: DiagnosticViewModel(session: session))
    }

    // MARK: - Suggested prompts

    /// Quick-tap prompt chips displayed above the input field.
    /// Ordered from most clinically urgent to most pedagogical.
    private let suggestedPrompts = [
        "What tests would you order?",
        "What exam finding would change your thinking?",
        "Summarize for my attending",
        "What's the most dangerous diagnosis to miss?",
    ]

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {

            // ── Scrollable message list ───────────────────────────────────────
            chatScrollView

            Divider()

            // ── Suggested prompt chips ────────────────────────────────────────
            suggestedChipsStrip
                .padding(.vertical, 8)

            Divider()

            // ── Text input bar ────────────────────────────────────────────────
            inputBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .navigationTitle("AI Diagnostic Partner")
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            "Consultation Error",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.clearError() } }
            )
        ) {
            Button("OK", role: .cancel) { viewModel.clearError() }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    // MARK: - Chat scroll view

    private var chatScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {

                    // Completed conversation turns.
                    // Use a helper func to pass the array explicitly — avoids Binding<C>
                    // overload ambiguity from the InferIsolatedConformances feature flag.
                    messageRows(viewModel.messages)

                    // Live streaming bubble — visible while tokens are arriving.
                    if !viewModel.streamingText.isEmpty {
                        ChatBubbleView(
                            role: "assistant",
                            content: viewModel.streamingText,
                            isStreaming: true
                        )
                        .padding(.horizontal, 16)
                    }

                    // Typing indicator — shown while waiting for the first token.
                    if viewModel.isThinking && viewModel.streamingText.isEmpty {
                        typingBubble
                            .padding(.horizontal, 16)
                    }

                    // Invisible anchor at the very bottom of the list.
                    // scrollTo("scroll-bottom") always jumps to here.
                    Color.clear
                        .frame(height: 1)
                        .id("scroll-bottom")
                }
                .padding(.top, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            // Scroll to bottom when a completed message is added.
            .onChange(of: viewModel.messages.count) { _, _ in
                withAnimation(.spring(duration: 0.3)) {
                    proxy.scrollTo("scroll-bottom", anchor: .bottom)
                }
            }
            // Scroll to bottom on every streaming token so the live text stays visible.
            .onChange(of: viewModel.streamingText) { _, _ in
                proxy.scrollTo("scroll-bottom", anchor: .bottom)
            }
            // Scroll to bottom when the typing indicator first appears.
            .onChange(of: viewModel.isThinking) { _, thinking in
                if thinking {
                    proxy.scrollTo("scroll-bottom", anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Message rows helper

    /// Renders one ChatBubbleView per conversation turn.
    ///
    /// Accepts the array as an explicit parameter to give the compiler a concrete
    /// element type and avoid Binding<C> overload ambiguity in SwiftUI's ForEach.
    @ViewBuilder
    private func messageRows(_ items: [DiagnosticChatMessage]) -> some View {
        ForEach(items) { (message: DiagnosticChatMessage) in
            ChatBubbleView(role: message.role, content: message.content)
                .padding(.horizontal, 16)
        }
    }

    // MARK: - Typing bubble

    /// The three-dot animation shown while waiting for Claude's first token.
    private var typingBubble: some View {
        HStack(alignment: .bottom) {
            TypingIndicatorView()
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    Color.blue.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
            Spacer()
        }
    }

    // MARK: - Suggested chips strip

    private var suggestedChipsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestedPrompts, id: \.self) { prompt in
                    Button {
                        Task { await viewModel.sendMessage(text: prompt) }
                    } label: {
                        Text(prompt)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color(.separator), lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isThinking)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {

            // Multi-line text input — grows from 1 to 4 lines as the physician types.
            TextField("Ask about this patient…", text: $inputText, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18))

            // Send button — disabled while empty or while AI is responding.
            Button {
                let text = inputText
                inputText = ""
                Task { await viewModel.sendMessage(text: text) }
            } label: {
                // Full opacity when sendable; dimmed when waiting or empty.
                let canSend = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !viewModel.isThinking
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.blue)
                    .opacity(canSend ? 1.0 : 0.3)
            }
            .disabled(
                inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || viewModel.isThinking
            )
        }
    }
}

// MARK: - ChatBubbleView

/// Renders a single chat turn as a rounded bubble.
///
/// Physician bubbles ("user") are right-aligned with a white background and thin border.
/// AI bubbles ("assistant") are left-aligned with a light blue background.
///
/// When `isStreaming` is true, a small "typing…" indicator appears below the bubble
/// to signal that the text is still being generated.
private struct ChatBubbleView: View {
    let role: String
    let content: String
    var isStreaming: Bool = false

    private var isUser: Bool { role == "user" }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {

            // Push user bubbles to the right by leaving space on the left.
            if isUser {
                Spacer(minLength: 52)
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
                Text(content)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        isUser
                            ? Color(.systemBackground)
                            : Color.blue.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(
                                isUser ? Color(.separator) : Color.clear,
                                lineWidth: 0.5
                            )
                    )

                // "typing…" caption while the stream is building.
                if isStreaming {
                    Text("typing…")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, isUser ? 0 : 4)
                        .padding(.trailing, isUser ? 4 : 0)
                }
            }

            // Push AI bubbles to the left by leaving space on the right.
            if !isUser {
                Spacer(minLength: 52)
            }
        }
    }
}

// MARK: - TypingIndicatorView

/// Three animated dots that bounce in sequence to indicate the AI is thinking.
///
/// Designed to fit inside the light-blue AI bubble background in `typingBubble`.
/// Animation starts on `.onAppear` and naturally stops when the view is removed.
private struct TypingIndicatorView: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 7, height: 7)
                    .offset(y: animating ? -4 : 4)
                    .animation(
                        .easeInOut(duration: 0.4)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
        .onDisappear { animating = false }
    }
}

// MARK: - Preview

#Preview {
    let sampleSession = EncounterSession(
        id: UUID(),
        startTime: Date().addingTimeInterval(-900),
        endTime: nil,
        audioSegments: [
            TimestampedAudio(
                timestamp: 0,
                durationSeconds: 30,
                transcription: "Patient reports 3-day history of productive cough and fever. Denies chest pain."
            ),
        ],
        examFindings: [
            ExamFinding(
                id: UUID(),
                timestamp: 120,
                image: nil,
                annotation: "Right lower lobe crackles on auscultation",
                bodySystem: .pulmonary
            ),
        ],
        status: .recording
    )

    NavigationStack {
        DiagnosticView(session: sampleSession)
    }
}
