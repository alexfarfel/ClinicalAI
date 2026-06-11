// EncounterView.swift
// ClinicalAI — Active Encounter UI
//
// The primary screen physicians use during a patient visit. Adapts to the
// EncounterViewModel's state machine:
//
//   idle         → connect-glasses prompt
//   connecting   → scanning animation + discovered-device picker
//   recording    → timer · waveform · capture button · end button
//   processingNote → recording view + processing overlay
//   complete     → automatic navigation to NoteView
//
// Hardware button presses and on-screen taps call the same ViewModel methods,
// so behavior is identical regardless of input source.
//
// Production: EncounterViewModel() uses GlassesService (real MWDAT SDK) by default.
// For Previews/simulator, pass EncounterViewModel(glassesService: MockGlassesService()).

import SwiftUI
import UIKit

// MARK: - EncounterView

struct EncounterView: View {

    /// The ViewModel is owned here (not in a parent) so its lifecycle matches the view.
    /// GlassesService() is passed explicitly so the real MWDAT SDK is used in production.
    /// EncounterView is implicitly @MainActor so GlassesService() (also @MainActor) is valid here.
    @State private var viewModel = EncounterViewModel(glassesService: GlassesService())

    // ── View-only state ───────────────────────────────────────────────────────────
    @State private var showAnnotationSheet = false
    @State private var annotationText = ""
    @State private var showHardwareMapping = false
    @State private var showNoteView = false
    @State private var showFlash = false

    var body: some View {
        NavigationStack {
            ZStack {
                mainContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Full-screen green flash — confirmed hardware button press.
                Color.green
                    .opacity(showFlash ? 0.18 : 0)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .animation(.easeOut(duration: 0.5), value: showFlash)

                // Dimmed overlay + spinner during note generation.
                if viewModel.isGeneratingNote {
                    processingOverlay
                }
            }
            .navigationTitle("Encounter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            // ── Sheets ────────────────────────────────────────────────────────────
            .sheet(isPresented: $showAnnotationSheet) { annotationSheet }
            .sheet(isPresented: $showHardwareMapping) { HardwareMappingView() }
            // ── Navigation ────────────────────────────────────────────────────────
            // Pass both the note and session — NoteViewModel needs the session
            // to show exam-finding thumbnails and to support note regeneration.
            .navigationDestination(isPresented: $showNoteView) {
                if let note = viewModel.generatedNote,
                   let session = viewModel.currentSession {
                    NoteView(note: note, session: session)
                }
            }
            // ── Reactive responses ────────────────────────────────────────────────
            .onChange(of: viewModel.state) { _, newState in
                if newState == .complete { showNoteView = true }
            }
            .onChange(of: viewModel.lastHardwareTrigger) { _, newValue in
                guard newValue != nil else { return }
                triggerFlashAnimation()
            }
            .alert(
                "Error",
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
    }

    // MARK: - Main content switcher

    @ViewBuilder
    private var mainContent: some View {
        switch viewModel.state {
        case .idle:
            idleView
        case .connecting:
            connectingView
        case .recording, .processingNote, .complete:
            recordingView
        }
    }

    // MARK: - Idle view

    private var idleView: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "eyeglasses")
                .font(.system(size: 72, weight: .thin))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Text("Ready to start an encounter")
                    .font(.title2.weight(.semibold))
                Text("Tap below to grant camera permission and\nsearch for your nearby Meta AI glasses.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            Button {
                Task { await viewModel.startDiscovery() }
            } label: {
                Label("Find Glasses", systemImage: "eyeglasses")
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

    // MARK: - Connecting view

    private var connectingView: some View {
        VStack(spacing: 0) {
            connectionStatusBar
                .padding(.horizontal)
                .padding(.top, 8)

            if viewModel.discoveredDevices.isEmpty {
                // Still scanning — show a spinner.
                VStack(spacing: 20) {
                    Spacer()
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Scanning for glasses…")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                // Devices found — let the physician choose.
                // Pass the array explicitly so the compiler can resolve the concrete
                // element type without ambiguity from @Observable + @State inference.
                List {
                    deviceListRows(viewModel.discoveredDevices)
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    // MARK: - Recording view

    private var recordingView: some View {
        VStack(spacing: 0) {

            // ── Connection bar ──────────────────────────────────────────────────
            connectionStatusBar
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 4)

            Divider()

            ScrollView {
                VStack(spacing: 20) {

                    // ── Elapsed time ──────────────────────────────────────────────
                    VStack(spacing: 4) {
                        Text(formatElapsed(viewModel.elapsedTime))
                            .font(.system(size: 64, weight: .thin, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(viewModel.state == .recording ? .primary : .secondary)

                        Text(viewModel.state == .recording ? "Recording" : "Paused")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 16)

                    // ── Animated waveform ─────────────────────────────────────────
                    AnimatedWaveformView(isAnimating: viewModel.state == .recording)
                        .padding(.horizontal, 24)

                    // ── Captured findings row ─────────────────────────────────────
                    if let findings = viewModel.currentSession?.examFindings, !findings.isEmpty {
                        findingsRow(findings)
                    }

                    Spacer(minLength: 16)
                }
            }

            Divider()

            // ── Bottom controls ─────────────────────────────────────────────────
            VStack(spacing: 12) {
                captureSection
                endButton
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Device list rows

    /// Renders one list row per discovered glasses device.
    /// Accepts the array as an explicit parameter so Swift can resolve GlassesDevice
    /// as a concrete (non-binding) type in the ForEach without actor-isolation ambiguity.
    @ViewBuilder
    private func deviceListRows(_ devices: [GlassesDevice]) -> some View {
        ForEach(devices, id: \GlassesDevice.id) { (device: GlassesDevice) in
            Button {
                Task { await viewModel.connect(to: device) }
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "eyeglasses")
                        .font(.title2)
                        .foregroundStyle(.blue)
                        .frame(width: 36)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                        Text("Signal: \(device.signalStrength) dBm")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Findings row

    private func findingsRow(_ findings: [ExamFinding]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Captured Findings (\(findings.count))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(findings) { finding in
                        FindingThumbnailView(finding: finding)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    // MARK: - Capture section

    private var captureSection: some View {
        VStack(spacing: 6) {
            Button {
                showAnnotationSheet = true
            } label: {
                Label("Capture Exam Finding", systemImage: "camera.viewfinder")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .disabled(viewModel.state != .recording)

            // Hardware hint — derived from the live mapping so it updates if the
            // physician reconfigures their button assignments in HardwareMappingView.
            if let hint = captureHardwareHint {
                HStack(spacing: 4) {
                    Image(systemName: "hand.tap")
                        .font(.caption2)
                    Text(hint)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    /// First hardware input that currently maps to captureExamFinding, formatted as a hint.
    private var captureHardwareHint: String? {
        let m = HardwareActionMapping.load()
        if m.cameraButtonPressed == .captureExamFinding { return "or press camera button on glasses" }
        if m.sideDoubleTap       == .captureExamFinding { return "or double-tap the side arm" }
        if m.sideSingleTap       == .captureExamFinding { return "or single-tap the side arm" }
        if m.longPressSide       == .captureExamFinding { return "or long-press the side arm" }
        if m.voiceCommandDetected == .captureExamFinding { return "or use a voice command" }
        return nil
    }

    // MARK: - End encounter button

    private var endButton: some View {
        Button {
            Task { await viewModel.endEncounter() }
        } label: {
            Label("End Encounter", systemImage: "stop.circle.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .disabled(viewModel.state != .recording)
    }

    // MARK: - Connection status bar

    private var connectionStatusBar: some View {
        HStack(spacing: 8) {
            // Pulsing dot
            Circle()
                .fill(connectionDotColor)
                .frame(width: 9, height: 9)
                .shadow(color: connectionDotColor.opacity(0.6), radius: 4)

            Text(connectionStatusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }

    private var connectionDotColor: Color {
        switch viewModel.connectionStatus {
        case .disconnected:  return .gray
        case .scanning:      return .yellow
        case .connecting:    return .orange
        case .connected:     return .green
        case .error:         return .red
        }
    }

    private var connectionStatusText: String {
        switch viewModel.connectionStatus {
        case .disconnected:       return "Not connected"
        case .scanning:           return "Scanning for glasses…"
        case .connecting:         return "Connecting…"
        case .connected:          return "Glasses connected"
        case .error(let message): return "Connection error: \(message)"
        }
    }

    // MARK: - Processing overlay

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                ProgressView()
                    .scaleEffect(1.6)
                    .tint(.white)

                VStack(spacing: 6) {
                    Text("Generating Clinical Note")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("Claude is analysing the encounter transcript\nand exam findings.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                }
            }
            .padding(36)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 40)
        }
    }

    // MARK: - Annotation sheet

    private var annotationSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        "e.g., Right lower lobe crackles",
                        text: $annotationText,
                        axis: .vertical
                    )
                    .lineLimit(3...6)
                    .autocorrectionDisabled()
                } header: {
                    Text("What are you examining?")
                } footer: {
                    Text("Leave blank to capture immediately. You can add details after the encounter ends.")
                }
            }
            .navigationTitle("Exam Finding")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        annotationText = ""
                        showAnnotationSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Capture") {
                        let text = annotationText
                        annotationText = ""
                        showAnnotationSheet = false
                        Task { await viewModel.captureExamFinding(annotation: text) }
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showHardwareMapping = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Hardware Button Settings")
        }
    }

    // MARK: - Helpers

    private func triggerFlashAnimation() {
        showFlash = true
        Task {
            try? await Task.sleep(for: .milliseconds(420))
            showFlash = false
        }
    }

    private func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - AnimatedWaveformView

/// A row of animated bars that bounce while recording is active.
private struct AnimatedWaveformView: View {
    let isAnimating: Bool

    @State private var heights: [CGFloat] = Array(repeating: 4, count: 28)

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(heights.enumerated()), id: \.offset) { _, h in
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.red, .red.opacity(0.5)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 3, height: h)
                    .animation(.easeInOut(duration: 0.1), value: h)
            }
        }
        .frame(height: 50)
        // task(id:) restarts the task each time isAnimating flips.
        .task(id: isAnimating) {
            guard isAnimating else {
                heights = Array(repeating: 4, count: 28)
                return
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { break }
                heights = (0..<28).map { _ in CGFloat.random(in: 4...44) }
            }
        }
    }
}

// MARK: - FindingThumbnailView

/// Compact thumbnail shown in the horizontal findings row during recording.
private struct FindingThumbnailView: View {
    let finding: ExamFinding

    var body: some View {
        VStack(spacing: 5) {
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
            .frame(width: 58, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color(.separator), lineWidth: 0.5)
            )

            Text(finding.annotation.isEmpty ? finding.bodySystem.displayName : finding.annotation)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 62)
        }
    }
}

// MARK: - Previews

#Preview("Idle") {
    EncounterView()
}

#Preview("Recording") {
    EncounterView()
}
