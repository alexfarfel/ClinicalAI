// EncounterViewModel.swift
// ClinicalAI — Encounter Business Logic
//
// Manages the full lifecycle of one patient encounter:
//   idle → connecting → recording → processingNote → complete
//
// Hardware events from GlassesService and on-screen button taps both converge on
// the same captureExamFinding() method, so behavior is identical regardless of
// which input source the physician uses.
//
// Concurrency model:
// - The class is @MainActor so all property mutations are on the main thread.
// - Background tasks (timer, polling, audio consumption) use [weak self] captures
//   and guard against nil self before mutating any state.
// - GlassesServiceProtocol is @MainActor, so reading its properties is safe here.

import Foundation

// MARK: - EncounterState

/// The UI lifecycle phase of the active encounter screen.
///
/// Distinct from `EncounterStatus` in the model layer (which tracks the persisted record).
/// This enum drives which UI elements are visible and which actions are available.
enum EncounterState: Equatable {
    /// No encounter in progress; waiting for the physician to start.
    case idle
    /// Bluetooth scan is running or SDK handshake is in progress.
    case connecting
    /// Encounter active — audio streaming, hardware events being processed.
    case recording
    /// Encounter ended — LLM is generating the SOAP note.
    case processingNote
    /// Note generated — trigger navigation to NoteView.
    case complete
}

// MARK: - EncounterViewModel

@Observable
@MainActor
final class EncounterViewModel {

    // MARK: - Injected services

    private let glassesService: any GlassesServiceProtocol
    private let llmService: any LLMServiceProtocol

    // MARK: - Observable state (read by the View)

    /// Current lifecycle phase. Drives all conditional UI rendering.
    private(set) var state: EncounterState = .idle

    /// Mirrors `GlassesService.connectionStatus`. Synced by the connection-polling task.
    private(set) var connectionStatus: ConnectionStatus = .disconnected

    /// Mirrors `GlassesService.discoveredDevices`. Synced by the connection-polling task.
    private(set) var discoveredDevices: [GlassesDevice] = []

    /// The active encounter session. Non-nil from recording start through note generation.
    private(set) var currentSession: EncounterSession?

    /// Seconds elapsed since the encounter started. Drives the on-screen timer display.
    private(set) var elapsedTime: TimeInterval = 0

    /// Set when Claude returns a note. Setting this triggers navigation to NoteView.
    private(set) var generatedNote: ClinicalNote?

    /// The most recent hardware event received from the glasses.
    /// Automatically cleared ~600 ms after being set; the View uses this to trigger
    /// the flash animation that confirms a button press was registered.
    private(set) var lastHardwareTrigger: GlassesHardwareEvent?

    /// Non-nil when an error alert should be shown to the physician.
    private(set) var errorMessage: String?

    /// Convenience accessor — true while the LLM call is in flight.
    var isGeneratingNote: Bool { state == .processingNote }

    // MARK: - Background tasks

    private var elapsedTimeTask: Task<Void, Never>?
    private var connectionPollingTask: Task<Void, Never>?
    private var audioConsumptionTask: Task<Void, Never>?
    private var hardwareTriggerClearTask: Task<Void, Never>?

    // MARK: - Init

    /// Creates the ViewModel with the services it depends on.
    ///
    /// The hardware event subscription starts immediately in a background Task and runs
    /// for the lifetime of the ViewModel. Events are silently ignored when
    /// `state != .recording`.
    ///
    /// Both parameters use opaque types (`some`) rather than existentials (`any`) so
    /// Swift can infer concrete types from the call site without boxing overhead.
    init(
        glassesService: some GlassesServiceProtocol,
        llmService: some LLMServiceProtocol
    ) {
        self.glassesService = glassesService
        self.llmService = llmService

        // Capture the stream value before entering the Task so the closure
        // only needs a weak reference to self (not to glassesService).
        let hardwareStream = glassesService.hardwareEvents
        Task { [weak self] in
            for await event in hardwareStream {
                guard let self else { break }
                await self.receiveHardwareEvent(event)
            }
        }
    }

    // MARK: - Public: connection flow

    /// Begins a Bluetooth scan for nearby glasses and populates `discoveredDevices`.
    ///
    /// Sets `state` to `.connecting`. When devices appear, the View shows a picker.
    /// The physician then calls `connect(to:)` to select a device.
    func startDiscovery() async {
        state = .connecting
        errorMessage = nil
        startConnectionPolling()
        do {
            try await glassesService.startDiscovery()
            // Sync after the call returns (mock populates devices before returning;
            // live SDK populates them via the polling task while the call is awaited).
            discoveredDevices = glassesService.discoveredDevices
            connectionStatus = glassesService.connectionStatus
        } catch {
            state = .idle
            stopConnectionPolling()
            errorMessage = "Bluetooth scan failed: \(error.localizedDescription)"
        }
    }

    /// Connects to a specific discovered device, then immediately starts recording.
    ///
    /// Physicians should not need to call this manually — the View calls it when
    /// they select a row from the discovered-devices list.
    func connect(to device: GlassesDevice) async {
        errorMessage = nil
        do {
            try await glassesService.connect(to: device)
            connectionStatus = glassesService.connectionStatus
            stopConnectionPolling()
            await startRecording()
        } catch {
            state = .idle
            stopConnectionPolling()
            connectionStatus = glassesService.connectionStatus
            errorMessage = "Could not connect to \(device.name): \(error.localizedDescription)"
        }
    }

    // MARK: - Public: encounter actions

    /// Captures an exam finding from the glasses camera and appends it to the session.
    ///
    /// **This is the single capture entry-point regardless of input source.**
    /// The on-screen "Capture Exam Finding" button calls this after collecting an
    /// annotation; hardware button presses call this immediately with an empty annotation.
    /// Behavior is identical either way — the physician can always annotate findings later.
    ///
    /// - Parameter annotation: Brief description typed by the physician
    ///   (e.g., "Right lower lobe crackles"). May be empty when triggered by hardware.
    func captureExamFinding(annotation: String) async {
        guard state == .recording, var session = currentSession else { return }

        let captureOffset = Date().timeIntervalSince(session.startTime)
        // Capture the photo — tolerate failure (finding is added without an image).
        let imageData: Data? = try? await glassesService.capturePhoto()

        let finding = ExamFinding(
            id: UUID(),
            timestamp: captureOffset,
            image: imageData,
            annotation: annotation,
            bodySystem: .general   // TODO: let physician choose body system in the annotation sheet
        )
        session.examFindings.append(finding)
        currentSession = session
    }

    /// Ends the active encounter, calls Claude for a SOAP note, and clears raw patient data.
    ///
    /// On success: `generatedNote` is set and `state` becomes `.complete`.
    /// On LLM failure: `state` reverts to `.recording` so the physician can retry.
    func endEncounter() async {
        guard state == .recording, let session = currentSession else { return }

        state = .processingNote
        stopElapsedTimer()
        glassesService.stopAudioCapture()
        audioConsumptionTask?.cancel()
        audioConsumptionTask = nil

        do {
            let note = try await llmService.generateNote(from: session)

            // Privacy rule: raw image bytes must be cleared after note generation.
            currentSession?.clearRawImageData()
            currentSession?.status = .complete

            generatedNote = note
            state = .complete
        } catch {
            // Allow physician to retry without losing the session.
            state = .recording
            errorMessage = "Note generation failed: \(error.localizedDescription)"
        }
    }

    /// Disconnects the glasses and resets the entire encounter screen to idle.
    func disconnect() {
        glassesService.stopAudioCapture()
        glassesService.disconnect()
        stopElapsedTimer()
        stopConnectionPolling()
        audioConsumptionTask?.cancel()
        audioConsumptionTask = nil
        connectionStatus = .disconnected
        discoveredDevices = []
        currentSession = nil
        elapsedTime = 0
        generatedNote = nil
        state = .idle
    }

    /// Dismisses the current error alert.
    func clearError() {
        errorMessage = nil
    }

    // MARK: - Private: recording lifecycle

    private func startRecording() async {
        let session = EncounterSession(
            id: UUID(),
            startTime: Date(),
            endTime: nil,
            audioSegments: [],
            examFindings: [],
            status: .recording
        )
        currentSession = session
        elapsedTime = 0
        state = .recording
        startElapsedTimer()

        // Start audio capture and drain the stream in a background task.
        // TODO: Feed each AudioChunk to SFSpeechRecognizer for real-time transcription.
        //       When the recogniser returns text, construct a TimestampedAudio and append:
        //       currentSession?.audioSegments.append(
        //           TimestampedAudio(timestamp: chunk.timestamp, durationSeconds: ..., transcription: text)
        //       )
        if let audioStream = try? await glassesService.startAudioCapture() {
            audioConsumptionTask = Task { [weak self] in
                for await _ in audioStream {
                    guard let self, self.state == .recording else { break }
                    // Drain the stream to keep the audio pipeline active.
                }
            }
        }
    }

    // MARK: - Private: hardware events

    private func receiveHardwareEvent(_ event: GlassesHardwareEvent) async {
        // Ignore hardware events outside of an active recording.
        guard state == .recording else { return }

        // Show flash animation in the View.
        setHardwareTrigger(event)

        // Reload the mapping on every event so Settings changes apply immediately.
        let mapping = HardwareActionMapping.load()
        let action = mapping.action(for: event)
        await executeAction(action)
    }

    /// Executes a GlassesAction — the common handler for both hardware and on-screen inputs.
    private func executeAction(_ action: GlassesAction) async {
        switch action {
        case .captureExamFinding:
            // Empty annotation when hardware-triggered; physician annotates afterwards.
            await captureExamFinding(annotation: "")
        case .startRecording:
            // Fires if the physician mapped single-tap to startRecording and presses
            // it while connected but before a recording has begun.
            if state == .connecting {
                await startRecording()
            }
        case .stopRecording:
            await endEncounter()
        case .dismiss:
            // Dismiss is purely UI-level; no ViewModel action needed here.
            // EncounterView observes lastHardwareTrigger and can respond to .dismiss
            // to close any open sheet.
            break
        }
    }

    // MARK: - Private: elapsed timer

    private func startElapsedTimer() {
        elapsedTimeTask?.cancel()
        elapsedTimeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let session = self.currentSession else { break }
                self.elapsedTime = Date().timeIntervalSince(session.startTime)
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimeTask?.cancel()
        elapsedTimeTask = nil
    }

    // MARK: - Private: connection polling

    /// Polls the glasses service for connectionStatus and discoveredDevices at 250 ms intervals.
    ///
    /// Required because GlassesServiceProtocol is stored as an existential (`any`), which
    /// prevents SwiftUI's `@Observable` machinery from tracking the service's property
    /// changes directly. Polling bridges the gap until the Meta SDK integration provides
    /// a delegate-callback based update mechanism.
    private func startConnectionPolling() {
        connectionPollingTask?.cancel()
        connectionPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                self.connectionStatus = self.glassesService.connectionStatus
                self.discoveredDevices = self.glassesService.discoveredDevices
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func stopConnectionPolling() {
        connectionPollingTask?.cancel()
        connectionPollingTask = nil
    }

    // MARK: - Private: hardware trigger feedback

    /// Sets `lastHardwareTrigger` and schedules its automatic clearance after 600 ms.
    ///
    /// The 600 ms window matches the flash animation duration in EncounterView,
    /// ensuring the trigger is cleared once the animation completes.
    private func setHardwareTrigger(_ event: GlassesHardwareEvent) {
        lastHardwareTrigger = event
        hardwareTriggerClearTask?.cancel()
        hardwareTriggerClearTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            self?.lastHardwareTrigger = nil
        }
    }
}
