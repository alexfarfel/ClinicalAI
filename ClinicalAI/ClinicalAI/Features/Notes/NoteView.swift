// NoteView.swift
// ClinicalAI — SOAP Note Review and Export
//
// The post-encounter screen where the physician reviews, edits, and exports
// the SOAP note Claude generated from the encounter audio and exam images.
//
// Layout (top to bottom):
//   ┌────────────────────────────────────────────────────┐
//   │  AI-Assisted Clinical Note     [Reviewed ✓]        │  ← meta header
//   │  Generated Jun 10, 2026 at 2:34 PM                 │
//   ├────────────────────────────────────────────────────┤
//   │  [👤] Chief Complaint            ▾                 │  ← collapsed card
//   │  Productive cough and fever...                     │
//   ├────────────────────────────────────────────────────┤
//   │  [🕐] History of Present Illness ▾                 │
//   │  Patient is a 52-year-old...                       │
//   ├────────────────────────────────────────────────────┤
//   │  [🩺] Physical Examination       ▴  ← expanded    │
//   │  ┌──────┐ ┌──────┐                                 │  ← thumbnails
//   │  │ img1 │ │ img2 │                                 │
//   │  └──────┘ └──────┘                                 │
//   │  [editable TextEditor]                             │
//   ├────────────────────────────────────────────────────┤
//   │  [☑] Assessment                  ▾                 │
//   │  [↺] Regenerate Note                               │
//   └────────────────────────────────────────────────────┘
//
// Toolbar: [✏ Edit All]  [⬆ Export to EHR]

import SwiftUI
import UIKit

// MARK: - NoteView

struct NoteView: View {

    // ── ViewModel ──────────────────────────────────────────────────────────────
    @State private var viewModel: NoteViewModel

    // ── View-only UI state ────────────────────────────────────────────────────

    /// When true, all five section cards simultaneously enter TextEditor mode.
    @State private var isEditingAll = false

    /// Non-nil when the physician tapped an exam-finding thumbnail;
    /// drives the full-screen image viewer sheet.
    @State private var fullScreenImageData: Data?

    // MARK: - Init

    init(note: ClinicalNote, session: EncounterSession) {
        _viewModel = State(wrappedValue: NoteViewModel(note: note, session: session))
    }

    // MARK: - Body

    var body: some View {
        // Bindable(viewModel) lets us pass live Binding<String> values into the
        // section cards. Each card can then read and write the field directly,
        // which is reflected immediately in isDirty / formattedNoteText.
        let bound = Bindable(viewModel)

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // ── Note meta header ──────────────────────────────────────────
                noteMetaHeader
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 16)

                Divider()

                // ── SOAP section cards ────────────────────────────────────────
                VStack(spacing: 12) {

                    SoapSectionCard(
                        title: "Chief Complaint",
                        icon: "person.fill.questionmark",
                        accentColor: .blue,
                        text: bound.chiefComplaint,
                        isEditingAll: isEditingAll
                    )

                    SoapSectionCard(
                        title: "History of Present Illness",
                        icon: "clock.arrow.circlepath",
                        accentColor: .purple,
                        text: bound.hpi,
                        isEditingAll: isEditingAll
                    )

                    // Physical Exam is the only card that shows exam-finding thumbnails.
                    SoapSectionCard(
                        title: "Physical Examination",
                        icon: "stethoscope",
                        accentColor: .teal,
                        text: bound.physicalExam,
                        isEditingAll: isEditingAll,
                        findings: viewModel.examFindings,
                        onFindingTapped: { imageData in
                            fullScreenImageData = imageData
                        }
                    )

                    SoapSectionCard(
                        title: "Assessment",
                        icon: "list.bullet.clipboard",
                        accentColor: .orange,
                        text: bound.assessment,
                        isEditingAll: isEditingAll
                    )

                    SoapSectionCard(
                        title: "Plan",
                        icon: "checklist",
                        accentColor: .green,
                        text: bound.plan,
                        isEditingAll: isEditingAll
                    )
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 16)

                // ── Regenerate section ────────────────────────────────────────
                regenerateSection
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)

                // ── Attestation footer (only when physician has edited) ────────
                if viewModel.isDirty {
                    attestationFooter
                        .padding(.horizontal, 20)
                        .padding(.bottom, 32)
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Clinical Note")
        .navigationBarTitleDisplayMode(.large)
        .toolbar { toolbarContent }
        // ── Export confirmation banner (overlaid at the top of the screen) ────
        .overlay(alignment: .top) {
            if viewModel.showExportConfirmation {
                exportBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 8)
            }
        }
        .animation(.spring(duration: 0.35), value: viewModel.showExportConfirmation)
        // Auto-dismiss the banner 2 seconds after it appears.
        .onChange(of: viewModel.showExportConfirmation) { _, isShowing in
            guard isShowing else { return }
            Task {
                try? await Task.sleep(for: .seconds(2))
                viewModel.showExportConfirmation = false
            }
        }
        // ── Full-screen exam image viewer ─────────────────────────────────────
        .fullScreenCover(
            isPresented: Binding(
                get: { fullScreenImageData != nil },
                set: { if !$0 { fullScreenImageData = nil } }
            )
        ) {
            // Pass through a local binding so the sheet can dismiss itself.
            FullScreenFindingViewer(imageData: fullScreenImageData) {
                fullScreenImageData = nil
            }
        }
        // ── Regeneration error alert ──────────────────────────────────────────
        .alert(
            "Regeneration Failed",
            isPresented: Binding(
                get: { viewModel.regenerationError != nil },
                set: { if !$0 { viewModel.regenerationError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { viewModel.regenerationError = nil }
        } message: {
            Text(viewModel.regenerationError ?? "")
        }
    }

    // MARK: - Note meta header

    private var noteMetaHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("AI-Assisted Clinical Note")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                // Composing Text views lets us reuse Date format styles without
                // building a manual DateFormatter.
                (
                    Text("Generated ")
                    + Text(viewModel.generatedAt, style: .date)
                    + Text(" at ")
                    + Text(viewModel.generatedAt, style: .time)
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            // Reviewed/pending badge — updates as soon as any SOAP field is edited.
            Group {
                if viewModel.isDirty {
                    Label("Reviewed", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Pending review", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption.weight(.medium))
        }
    }

    // MARK: - Regenerate section

    private var regenerateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await viewModel.regenerateNote() }
            } label: {
                HStack(spacing: 8) {
                    if viewModel.isRegenerating {
                        ProgressView()
                            .scaleEffect(0.85)
                        Text("Regenerating…")
                    } else {
                        Image(systemName: "arrow.clockwise")
                        Text("Regenerate Note")
                    }
                }
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .tint(.secondary)
            .disabled(viewModel.isRegenerating)

            Text("Regenerate sends the original encounter audio and images back to Claude and\nreplaces all sections with the new result.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Attestation footer

    private var attestationFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("This note was generated by ClinicalAI (AI-assisted) and reviewed and amended by the attending physician.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Export confirmation banner

    private var exportBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.doc.fill")
                .font(.subheadline)
            Text("Note copied to clipboard")
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        )
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // "Edit All" collapses/expands all cards simultaneously.
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                withAnimation(.spring(duration: 0.3)) {
                    isEditingAll.toggle()
                }
            } label: {
                Label(
                    isEditingAll ? "Done Editing" : "Edit All",
                    systemImage: isEditingAll ? "checkmark.circle.fill" : "pencil"
                )
            }
            .tint(isEditingAll ? .blue : .primary)
        }

        // "Export to EHR" — write to clipboard here (UIKit lives in the View layer),
        // then notify the ViewModel so it can set the confirmation-banner flag.
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                UIPasteboard.general.string = viewModel.formattedNoteText
                viewModel.exportNote()
            } label: {
                Label("Export to EHR", systemImage: "square.and.arrow.up")
            }
        }
    }
}

// MARK: - SoapSectionCard

/// A card representing one SOAP section. Tapping the header expands the card to
/// reveal an inline TextEditor. Provides thumbnail display for Physical Exam findings.
///
/// - Parameters:
///   - findings:       Exam-finding images to display above the text field.
///                     Only the Physical Exam card passes values here; others leave it empty.
///   - onFindingTapped: Called with the image Data when the physician taps a thumbnail.
private struct SoapSectionCard: View {

    let title: String
    let icon: String
    let accentColor: Color
    @Binding var text: String
    let isEditingAll: Bool

    var findings: [ExamFinding] = []
    var onFindingTapped: (Data) -> Void = { _ in }

    /// True when this individual card has been manually tapped open.
    @State private var isExpanded = false

    /// Combines the per-card toggle with the global "Edit All" state.
    private var isInEditMode: Bool { isExpanded || isEditingAll }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Card header (always visible) ──────────────────────────────────
            Button {
                withAnimation(.spring(duration: 0.3)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(accentColor)
                        .frame(width: 22)

                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Spacer()

                    // Chevron rotates 180° when the card is expanded.
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isInEditMode ? 180 : 0))
                        .animation(.spring(duration: 0.3), value: isInEditMode)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .buttonStyle(.plain)

            // ── Collapsed preview (one or two lines) ─────────────────────────
            if !isInEditMode {
                Text(text.isEmpty ? "—" : text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            }

            // ── Expanded: thumbnails + TextEditor ─────────────────────────────
            if isInEditMode {
                Divider()
                    .padding(.horizontal, 16)

                // Exam-finding thumbnails: shown only in Physical Exam and only
                // when at least one finding was captured during the encounter.
                let findingsWithImages = findings.filter { $0.image != nil }
                if !findingsWithImages.isEmpty {
                    findingsThumbnailStrip(findingsWithImages)
                        .padding(.top, 12)
                }

                // Inline text editor. scrollDisabled forces the editor to grow
                // to fit its content, letting the enclosing ScrollView handle scrolling.
                TextEditor(text: $text)
                    .scrollDisabled(true)
                    .scrollContentBackground(.hidden)
                    .font(.callout)
                    .frame(minHeight: 100, alignment: .topLeading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // Blue border when editing to give the physician a clear visual indicator.
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isInEditMode ? accentColor.opacity(0.4) : Color.clear,
                    lineWidth: 1.5
                )
        )
        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
        .animation(.spring(duration: 0.3), value: isInEditMode)
    }

    // MARK: - Finding thumbnails strip

    /// Horizontal row of exam-finding thumbnails shown inside the Physical Exam card.
    ///
    /// Only called when `findingsWithImages` is non-empty. Each thumbnail is a Button
    /// so the physician can tap to enlarge the photo.
    @ViewBuilder
    private func findingsThumbnailStrip(_ items: [ExamFinding]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Captured Findings")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    // Use explicit type annotation and key-path root to avoid Binding<C>
                    // overload ambiguity from the InferIsolatedConformances feature flag.
                    ForEach(items, id: \ExamFinding.id) { (finding: ExamFinding) in
                        findingThumbnailButton(finding)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    /// A tappable thumbnail for one exam finding.
    @ViewBuilder
    private func findingThumbnailButton(_ finding: ExamFinding) -> some View {
        Button {
            if let data = finding.image {
                onFindingTapped(data)
            }
        } label: {
            VStack(spacing: 5) {
                // Image or placeholder if data is unavailable.
                Group {
                    if let data = finding.image, let img = UIImage(data: data) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "camera.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(.tertiarySystemBackground))
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color(.separator), lineWidth: 0.5)
                )

                Text(finding.annotation.isEmpty
                     ? finding.bodySystem.displayName
                     : finding.annotation)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 68)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - FullScreenFindingViewer

/// Full-screen image viewer shown when the physician taps an exam-finding thumbnail.
/// Tapping anywhere (or dragging down) dismisses it.
private struct FullScreenFindingViewer: View {
    let imageData: Data?
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let data = imageData, let img = UIImage(data: data) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .padding()
            } else {
                // Fallback for missing image data (cleared for privacy after note generation).
                VStack(spacing: 12) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Image data has been cleared\nfor patient privacy.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            // Dismiss button in the top-right corner.
            VStack {
                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .white.opacity(0.3))
                    }
                    .padding()
                }
                Spacer()
            }
        }
        .onTapGesture { onDismiss() }
    }
}

// MARK: - Preview

#Preview {
    let sampleSession = EncounterSession(
        id: UUID(),
        startTime: Date().addingTimeInterval(-1800),
        endTime: Date(),
        audioSegments: [],
        examFindings: [
            ExamFinding(
                id: UUID(),
                timestamp: 300,
                image: nil,
                annotation: "Right lower lobe crackles",
                bodySystem: .pulmonary
            ),
        ],
        status: .complete
    )
    let sampleNote = ClinicalNote(
        id: UUID(),
        encounterSessionId: sampleSession.id,
        generatedAt: Date(),
        chiefComplaint: "Productive cough and fever for 3 days",
        historyOfPresentIllness: """
            52-year-old male with T2DM presenting with 3-day history of productive cough \
            with yellow-green sputum, fever 38.9°C at home, and right-sided pleuritic chest \
            pain that worsens with deep inspiration. He reports fatigue and decreased appetite. \
            He denies hemoptysis, orthopnea, or leg swelling.
            """,
        physicalExamFindings: """
            Temp 38.6°C, HR 98, BP 138/84, RR 20, O2 sat 95% RA. Dullness to percussion \
            right lower lobe. Crackles and bronchial breath sounds right lower lobe. \
            Left lung fields clear. Cardiac: RRR, no murmurs.
            """,
        assessment: """
            1. Community-acquired pneumonia, right lower lobe (CURB-65 score 1).
            2. Type 2 diabetes mellitus — unrelated to current presentation.
            """,
        plan: """
            1. Amoxicillin-clavulanate 875/125 mg PO BID × 5 days.
            2. Azithromycin 500 mg PO Day 1, then 250 mg Days 2–5.
            3. Acetaminophen 1000 mg PO q6h PRN fever/pain.
            4. Follow-up 48–72 hours or sooner if O2 sat < 92%.
            """,
        rawJSON: "{}",
        isEdited: false
    )

    NavigationStack {
        NoteView(note: sampleNote, session: sampleSession)
    }
}
