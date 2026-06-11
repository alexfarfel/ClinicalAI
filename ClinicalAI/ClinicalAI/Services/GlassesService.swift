// GlassesService.swift
// ClinicalAI — Meta AI Glasses Connection and Control
//
// Production implementation uses the Meta Wearables Device Access Toolkit (MWDAT):
//   Package:   https://github.com/facebook/meta-wearables-dat-ios
//   API ref:   https://wearables.developer.meta.com/llms.txt?full=true
//   Imports:   import MWDATCore, import MWDATCamera
//
// Architecture:
//   GlassesServiceProtocol  ←  what the rest of the app depends on
//   GlassesService           ←  real SDK, requires paired Ray-Ban Meta glasses
//   MockGlassesService       ←  synthetic data, works in the simulator without hardware
//
// ── SDK type cheat-sheet (verified against swiftinterface) ────────────────────
// • DeviceIdentifier         = typealias String
// • Wearables.shared         returns any WearablesInterface
// • WearablesInterface.devicesStream()  → AsyncStream<[DeviceIdentifier]>
// • WearablesInterface.deviceForIdentifier(_:) → Device? (has .name: String)
// • WearablesInterface.createSession(deviceSelector:) throws(DeviceSessionError) → DeviceSession
// • DeviceSession.start()    synchronous, throws(DeviceSessionError)   — NOT async
// • DeviceSession.stop()     synchronous, no throws                    — NOT async
// • DeviceSession.stateStream() → AsyncStream<DeviceSessionState>
//   DeviceSessionState cases: .idle .starting .started .paused .stopping .stopped
// • DeviceSession.addStream(config:) throws(DeviceSessionError) → Stream?
// • Stream.start()           async, non-throwing
// • Stream.stop()            async, non-throwing
// • Stream.capturePhoto(format:) → Bool   @discardableResult — NOT throwing
// • Stream.videoFramePublisher / photoDataPublisher  are any Announcer<T>, use .listen(_:)
// • StreamConfiguration.init(videoCodec:resolution:frameRate:) — frameRate is UInt
// • VideoCodec cases:  .raw  .hvc1   (NOT .h264)
// • PermissionStatus cases:  .granted  .denied   (NOT .unknown)
// • SpecificDeviceSelector.init(device: DeviceIdentifier)
// • AutoDeviceSelector.init(wearables: any WearablesInterface, filter: DeviceFilter? = nil)
// • AnyListenerToken.cancel() is async
//
// ── Audio note ────────────────────────────────────────────────────────────────
// Audio arrives via standard iOS Bluetooth (AVAudioSession/AVAudioEngine); the
// MWDAT SDK itself does not expose an audio stream API.

import AVFoundation
import Foundation
import MWDATCamera
import MWDATCore
import UIKit

// MARK: - ConnectionStatus

/// The Bluetooth / SDK connection lifecycle state of the glasses.
///
/// The UI observes this value to show the appropriate connection screen or warning banner.
/// Transitions always flow forward: disconnected → scanning → connecting → connected.
/// Any failure lands in `.error` and the user must restart discovery.
enum ConnectionStatus: Equatable {
    /// No glasses are paired; the app is idle.
    case disconnected

    /// Observing the MWDAT devices stream, waiting for paired glasses to appear.
    case scanning

    /// The app has chosen a device and is completing the SDK handshake.
    case connecting

    /// The glasses are paired and ready to record audio or capture photos.
    case connected

    /// Something went wrong. The associated string is a human-readable explanation
    /// suitable for display in an alert.
    case error(String)
}

// MARK: - GlassesDevice

/// A Meta AI glasses device discovered via MWDAT's `devicesStream()`.
///
/// The physician sees a list of these and taps one to connect.
/// Conforms to `Identifiable` so it can be used directly in SwiftUI `ForEach`.
struct GlassesDevice: Identifiable, Sendable {
    let id: UUID
    let name: String
    let signalStrength: Int
}


// MARK: - AudioChunk

/// A short burst of raw audio delivered by the glasses microphone via AVAudioEngine.
///
/// Audio is streamed in small chunks so the speech-to-text engine can process it
/// incrementally rather than waiting for the entire recording.
///
/// `Sendable` because chunks are delivered through an `AsyncStream` which crosses
/// actor / task boundaries.
struct AudioChunk: Sendable {
    /// Raw 16-bit little-endian PCM samples, 16 kHz, mono.
    /// This is the format expected by most on-device ASR engines (e.g., SFSpeechRecognizer).
    let data: Data

    /// Wall-clock time when this chunk was captured.
    let timestamp: Date

    /// Duration of this chunk in milliseconds (approximately 100 ms per chunk).
    let durationMs: Int
}

// MARK: - GlassesServiceError

/// Errors thrown by `GlassesServiceProtocol` methods.
enum GlassesServiceError: LocalizedError {
    /// Camera or Bluetooth permission was denied.
    case bluetoothUnauthorized

    /// The connection attempt did not complete (session start failed or timed out).
    case connectionTimeout

    /// A recording or photo was requested but no glasses are currently connected.
    case notConnected

    /// The glasses microphone stream could not be started or encountered an error.
    case audioCaptureFailed(String)

    /// The camera shutter request failed or returned no data.
    case photoCaptureFailed(String)

    var errorDescription: String? {
        switch self {
        case .bluetoothUnauthorized:
            return "Camera / Bluetooth permission is required. Enable it in Settings → Privacy, then pair the glasses in the Meta AI app."
        case .connectionTimeout:
            return "Could not connect to the glasses. Make sure they are powered on and nearby, and that the Meta AI app is installed."
        case .notConnected:
            return "No glasses are connected. Please connect before starting an encounter."
        case .audioCaptureFailed(let reason):
            return "Audio capture failed: \(reason)"
        case .photoCaptureFailed(let reason):
            return "Photo capture failed: \(reason)"
        }
    }
}

// MARK: - GlassesHardwareEvent

/// A physical input event generated by the glasses hardware.
///
/// These raw events are delivered through `GlassesServiceProtocol.hardwareEvents`.
/// The `EncounterViewModel` receives them and looks up the configured `GlassesAction`
/// via `HardwareActionMapping.load().action(for:)`.
///
/// `Sendable` because events travel through `AsyncStream` across task boundaries.
/// `Equatable` so the ViewModel can filter or deduplicate events if needed.
enum GlassesHardwareEvent: Sendable, Equatable {
    /// The dedicated camera button on the glasses frame was pressed.
    ///
    /// In the live SDK this is inferred from `photoDataPublisher` emitting without a
    /// concurrent `capturePhoto()` call. The physical button triggers a capture at the
    /// SDK level; the resulting photo data delivery is the observable signal.
    case cameraButtonPressed

    /// The touch-sensitive arm of the glasses was tapped twice quickly.
    case sideDoubleTap

    /// The touch-sensitive arm of the glasses was tapped once.
    case sideSingleTap

    /// The touch-sensitive arm of the glasses was held down.
    case longPressSide

    /// The glasses' voice-activation system recognised a spoken command.
    ///
    /// The associated `String` is the raw recognised text (e.g., `"capture finding"`).
    /// `HardwareActionMapping` maps the *type* of this event to an action; parsing the
    /// specific phrase for more granular commands is left to the ViewModel.
    case voiceCommandDetected(String)
}

// MARK: - GlassesAction

/// An app-level action triggered in response to a glasses hardware event.
enum GlassesAction: String, Codable, Equatable, CaseIterable {
    case captureExamFinding
    case startRecording
    case stopRecording
    case dismiss

    var displayName: String {
        switch self {
        case .captureExamFinding: return "Capture Exam Finding"
        case .startRecording:     return "Start Recording"
        case .stopRecording:      return "Stop Recording"
        case .dismiss:            return "Dismiss"
        }
    }
}

// MARK: - HardwareActionMapping

/// Maps each `GlassesHardwareEvent` type to the `GlassesAction` it should trigger.
///
/// Persisted as JSON in `UserDefaults` under `HardwareActionMapping.userDefaultsKey`
/// so the mapping can be reconfigured from a Settings screen without a code change.
struct HardwareActionMapping: Codable, Equatable {

    static let userDefaultsKey = "com.clinicalai.hardwareActionMapping"

    static func load() -> HardwareActionMapping {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let mapping = try? JSONDecoder().decode(HardwareActionMapping.self, from: data) else {
            return .default
        }
        return mapping
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: HardwareActionMapping.userDefaultsKey)
    }

    static let `default` = HardwareActionMapping(
        cameraButtonPressed:  .captureExamFinding,
        sideDoubleTap:        .captureExamFinding,
        sideSingleTap:        .startRecording,
        longPressSide:        .stopRecording,
        voiceCommandDetected: .captureExamFinding
    )

    var cameraButtonPressed:  GlassesAction
    var sideDoubleTap:        GlassesAction
    var sideSingleTap:        GlassesAction
    var longPressSide:        GlassesAction
    var voiceCommandDetected: GlassesAction

    func action(for event: GlassesHardwareEvent) -> GlassesAction {
        switch event {
        case .cameraButtonPressed:  return cameraButtonPressed
        case .sideDoubleTap:        return sideDoubleTap
        case .sideSingleTap:        return sideSingleTap
        case .longPressSide:        return longPressSide
        case .voiceCommandDetected: return voiceCommandDetected
        }
    }
}

// MARK: - GlassesServiceProtocol

/// The single interface through which all of the app's glasses-related functionality flows.
///
/// Both concrete implementations (`GlassesService` and `MockGlassesService`) satisfy
/// this protocol. ViewModels receive a `GlassesServiceProtocol` and never import the
/// MWDAT SDK directly.
protocol GlassesServiceProtocol: AnyObject {

    var connectionStatus: ConnectionStatus { get }
    var discoveredDevices: [GlassesDevice] { get }

    /// A continuous stream of raw hardware input events from the glasses.
    /// Long-lived; created once and never replaced. Events are not emitted while disconnected.
    var hardwareEvents: AsyncStream<GlassesHardwareEvent> { get }

    func startDiscovery() async throws
    func connect(to device: GlassesDevice) async throws
    func disconnect()
    func startAudioCapture() async throws -> AsyncStream<AudioChunk>
    func stopAudioCapture()
    func capturePhoto() async throws -> Data
}

// MARK: - Live Implementation

/// Production glasses service backed by the Meta Wearables Device Access Toolkit (MWDAT).
///
/// ## Dependency on Meta AI app
/// The glasses must be paired in the Meta AI app before they appear in `devicesStream()`.
/// On first use, call `startRegistration()` to open the Meta AI app's pairing flow.
///
/// ## Key SDK facts for maintainers
/// - `DeviceSession.start()` is synchronous (throws, not async).
/// - `DeviceSession.stop()` is synchronous and non-throwing.
/// - `Stream.capturePhoto(format:)` returns Bool and does not throw.
/// - Video and photo publishers use the `Announcer` pattern; subscribe with `.listen(_:)`.
@Observable
@MainActor
final class GlassesService: GlassesServiceProtocol {

    // ── Observable state ─────────────────────────────────────────────────────────

    private(set) var connectionStatus: ConnectionStatus = .disconnected
    private(set) var discoveredDevices: [GlassesDevice] = []

    /// Latest video frame from the glasses camera; nil when not streaming.
    /// Observe this in the encounter view to display a live POV preview during an exam.
    private(set) var latestVideoFrame: VideoFrame?

    // ── Hardware events ───────────────────────────────────────────────────────────

    private(set) var hardwareEvents: AsyncStream<GlassesHardwareEvent>
    private var hardwareEventContinuation: AsyncStream<GlassesHardwareEvent>.Continuation?

    // ── MWDAT SDK references ──────────────────────────────────────────────────────

    /// The shared MWDAT singleton. Typed as `any WearablesInterface` per the SDK.
    private let wearables: any WearablesInterface = Wearables.shared

    private var deviceSession: DeviceSession?
    private var cameraStream: MWDATCamera.Stream?

    /// Maps each `GlassesDevice.id` (our locally-generated UUID) to the SDK's
    /// `DeviceIdentifier` (String) so `connect(to:)` can build a `SpecificDeviceSelector`.
    private var deviceIdentifierMap: [UUID: DeviceIdentifier] = [:]

    // ── Photo capture bridge (Announcer callback → async/await) ──────────────────

    /// A single in-flight continuation awaiting a JPEG from `photoDataPublisher`.
    /// At most one `capturePhoto()` call may be in flight at a time.
    private var photoContinuation: CheckedContinuation<Data, Error>?

    // ── Listener tokens (replace publisher.values pattern) ───────────────────────

    /// Subscription token for the video-frame listener. Cancel on stream teardown.
    private var videoFrameListenerToken: (any AnyListenerToken)?

    /// Subscription token for the photo-data listener. Cancel on stream teardown.
    private var photoDataListenerToken: (any AnyListenerToken)?

    // ── Audio ─────────────────────────────────────────────────────────────────────

    private var audioEngine: AVAudioEngine?
    private var audioContinuation: AsyncStream<AudioChunk>.Continuation?

    // ── Background observation tasks ──────────────────────────────────────────────

    private var discoveryTask: Task<Void, Never>?
    private var sessionStateTask: Task<Void, Never>?

    // MARK: - Init

    init() {
        let (hwStream, hwContinuation) = AsyncStream.makeStream(of: GlassesHardwareEvent.self)
        self.hardwareEvents = hwStream
        self.hardwareEventContinuation = hwContinuation
    }

    // MARK: - GlassesServiceProtocol

    func startDiscovery() async throws {
        discoveredDevices = []
        deviceIdentifierMap = [:]
        connectionStatus = .scanning
        print("ClinicalAI 🔍 startDiscovery() — requesting camera permission")

        // Step 1: check/request camera permission before subscribing to devicesStream().
        // PermissionStatus has only .granted and .denied — default to .denied on error.
        let currentStatus = (try? await wearables.checkPermissionStatus(.camera)) ?? .denied
        print("ClinicalAI 🔍 camera permission check: \(currentStatus)")
        if currentStatus != .granted {
            print("ClinicalAI 🔍 camera not yet granted — requesting…")
            let requested = (try? await wearables.requestPermission(.camera)) ?? .denied
            print("ClinicalAI 🔍 camera permission after request: \(requested)")
            if requested != .granted {
                connectionStatus = .error("Camera permission denied. Grant access via the Meta AI app.")
                throw GlassesServiceError.bluetoothUnauthorized
            }
        }
        print("ClinicalAI 🔍 camera permission granted — subscribing to devicesStream()")

        // Step 2: subscribe to devicesStream(). Emits a fresh [DeviceIdentifier] array
        // each time the set of paired nearby glasses changes.
        discoveryTask?.cancel()
        discoveryTask = Task { [weak self] in
            guard let self else { return }
            for await identifiers in wearables.devicesStream() {
                guard !Task.isCancelled else { break }
                print("ClinicalAI 🔍 devicesStream() emitted \(identifiers.count) identifier(s): \(identifiers)")
                var map: [UUID: DeviceIdentifier] = [:]
                var list: [GlassesDevice] = []
                for identifier in identifiers {
                    let localID = UUID()
                    map[localID] = identifier
                    // deviceForIdentifier returns a Device? with a .name: String property.
                    let displayName = wearables.deviceForIdentifier(identifier)?.name ?? "Ray-Ban Meta"
                    print("ClinicalAI 🔍 found device: id=\(identifier) name=\(displayName)")
                    list.append(GlassesDevice(
                        id: localID,
                        name: displayName,
                        signalStrength: -60  // MWDAT does not expose RSSI; -60 dBm is typical
                    ))
                }
                self.deviceIdentifierMap = map
                self.discoveredDevices = list
                print("ClinicalAI 🔍 discoveredDevices updated: \(list.map(\.name))")
            }
            print("ClinicalAI 🔍 devicesStream() loop ended")
        }

        // Wait briefly so the first devicesStream() emission can arrive before we return.
        // EncounterViewModel polls discoveredDevices at 250 ms intervals, so this is fine.
        try await Task.sleep(for: .milliseconds(600))
        print("ClinicalAI 🔍 startDiscovery() returning — devices so far: \(discoveredDevices.map(\.name))")
    }

    func connect(to device: GlassesDevice) async throws {
        connectionStatus = .connecting
        discoveryTask?.cancel()
        discoveryTask = nil

        do {
            // Use SpecificDeviceSelector when we have the DeviceIdentifier from discovery;
            // fall back to AutoDeviceSelector if the mapping entry is missing.
            let session: DeviceSession
            if let identifier = deviceIdentifierMap[device.id] {
                session = try wearables.createSession(
                    deviceSelector: SpecificDeviceSelector(device: identifier)
                )
            } else {
                session = try wearables.createSession(
                    deviceSelector: AutoDeviceSelector(wearables: wearables)
                )
            }
            deviceSession = session

            // Observe session state so we can mirror it to connectionStatus.
            // Start the listener BEFORE calling session.start() so no events are missed.
            sessionStateTask?.cancel()
            sessionStateTask = Task { [weak self] in
                for await state in session.stateStream() {
                    guard let self, !Task.isCancelled else { break }
                    switch state {
                    case .started:
                        self.connectionStatus = .connected
                    case .stopped:
                        if self.connectionStatus == .connected || self.connectionStatus == .connecting {
                            self.connectionStatus = .disconnected
                        }
                    default:
                        break
                    }
                }
            }

            // session.start() is SYNCHRONOUS (throws DeviceSessionError), not async.
            try session.start()

            // Attach the camera stream for live preview and photo capture.
            try await setupCameraStream(on: session)

            // Belt-and-suspenders: also set status here in case stateStream fires late.
            connectionStatus = .connected

        } catch let svcError as GlassesServiceError {
            connectionStatus = .error(svcError.localizedDescription ?? "Connection failed")
            throw svcError
        } catch {
            connectionStatus = .error(error.localizedDescription)
            throw GlassesServiceError.connectionTimeout
        }
    }

    func disconnect() {
        stopAudioCapture()
        tearDownCameraStream()

        // DeviceSession.stop() is SYNCHRONOUS — no Task wrapper needed.
        let sessionToStop = deviceSession
        deviceSession = nil
        sessionToStop?.stop()

        discoveryTask?.cancel()
        discoveryTask = nil
        sessionStateTask?.cancel()
        sessionStateTask = nil

        deviceIdentifierMap = [:]
        discoveredDevices = []
        connectionStatus = .disconnected
    }

    func startAudioCapture() async throws -> AsyncStream<AudioChunk> {
        guard connectionStatus == .connected else {
            throw GlassesServiceError.notConnected
        }
        stopAudioCapture()

        // Audio from the Ray-Ban Meta glasses arrives via standard iOS Bluetooth audio
        // (HFP/HSP profile). Configure AVAudioSession to route input from the Bluetooth
        // device, then tap the AVAudioEngine input node for PCM buffers.
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        audioContinuation = continuation

        do {
            try configureAudioSession()
            try startAudioEngine(continuation: continuation)
        } catch {
            continuation.finish()
            audioContinuation = nil
            throw GlassesServiceError.audioCaptureFailed(error.localizedDescription)
        }

        return stream
    }

    func stopAudioCapture() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioContinuation?.finish()
        audioContinuation = nil
        // Release the Bluetooth audio route so other apps can use it.
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
    }

    func capturePhoto() async throws -> Data {
        guard connectionStatus == .connected, let stream = cameraStream else {
            throw GlassesServiceError.notConnected
        }
        guard photoContinuation == nil else {
            throw GlassesServiceError.photoCaptureFailed("A photo capture is already in progress.")
        }

        // Bridge the Announcer-style photoDataPublisher to async/await via a continuation.
        // capturePhoto(format:) tells the SDK to capture; the photo arrives on the
        // photoDataListenerToken callback which resolves this continuation.
        return try await withCheckedThrowingContinuation { [weak self] continuation in
            guard let self else {
                continuation.resume(throwing: GlassesServiceError.notConnected)
                return
            }
            self.photoContinuation = continuation
            // capturePhoto(format:) returns Bool and does NOT throw.
            let triggered = stream.capturePhoto(format: .jpeg)
            if !triggered {
                self.photoContinuation = nil
                continuation.resume(throwing: GlassesServiceError.photoCaptureFailed(
                    "capturePhoto(format:) returned false — glasses may not be ready."
                ))
            }
        }
    }

    // MARK: - Registration (called from ClinicalAIApp)

    /// Opens the Meta AI app to register ClinicalAI for glasses access.
    ///
    /// Call this if `discoveredDevices` remains empty after `startDiscovery()`.
    /// The physician completes pairing in the Meta AI app; on return, iOS calls the
    /// app's `onOpenURL` handler with a `clinicalai://` deep link which must be passed
    /// to `Wearables.shared.handleUrl(_:)` (wired up in ClinicalAIApp).
    func startRegistration() async throws {
        try await wearables.startRegistration()
    }

    /// Removes ClinicalAI's registration from the Meta AI app.
    func startUnregistration() async throws {
        try await wearables.startUnregistration()
    }

    // MARK: - Private: camera stream

    private func setupCameraStream(on session: DeviceSession) async throws {
        // Clinical exam capture profile:
        //   resolution: .medium — enough detail for skin findings, rashes, etc.
        //   frameRate: 15 fps — reduces battery drain; we want stills, not continuous video
        //   videoCodec: .hvc1 — hardware-accelerated H.265 on A-series chips
        //   Note: StreamConfiguration.frameRate is UInt, and VideoCodec is .hvc1 (not .h264)
        let config = StreamConfiguration(
            videoCodec: .hvc1,
            resolution: .medium,
            frameRate: 15
        )

        // addStream(config:) returns Stream? and throws DeviceSessionError.
        guard let stream = try session.addStream(config: config) else {
            // No camera capability available on this session — proceed without camera.
            return
        }
        cameraStream = stream

        // ── Live video preview ─────────────────────────────────────────────────────
        // videoFramePublisher is any Announcer<VideoFrame>; subscribe with .listen(_:).
        // The callback runs on the SDK's internal thread so we dispatch to @MainActor.
        videoFrameListenerToken = stream.videoFramePublisher.listen { @Sendable [weak self] frame in
            Task { @MainActor [weak self] in
                self?.latestVideoFrame = frame
            }
        }

        // ── Photo delivery and camera button detection ─────────────────────────────
        // photoDataPublisher fires in two situations:
        //   1. capturePhoto(format:) was called programmatically → resolve photoContinuation
        //   2. The camera button on the glasses was pressed → emit a hardware event
        // In both cases the data arrives here; we distinguish by checking photoContinuation.
        photoDataListenerToken = stream.photoDataPublisher.listen { @Sendable [weak self] photoData in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let continuation = self.photoContinuation {
                    // Resolve a capturePhoto() call that is awaiting this result.
                    self.photoContinuation = nil
                    continuation.resume(returning: photoData.data)
                } else {
                    // No programmatic capture in flight → physical camera button was pressed.
                    self.hardwareEventContinuation?.yield(.cameraButtonPressed)
                }
            }
        }

        // stream.start() IS async (unlike session.start() which is synchronous).
        await stream.start()
    }

    private func tearDownCameraStream() {
        // Cancel listener subscriptions asynchronously (AnyListenerToken.cancel() is async).
        let vft = videoFrameListenerToken
        let pdt = photoDataListenerToken
        videoFrameListenerToken = nil
        photoDataListenerToken = nil
        Task {
            await vft?.cancel()
            await pdt?.cancel()
        }

        // Stop the camera stream asynchronously (Stream.stop() is async).
        let streamToStop = cameraStream
        cameraStream = nil
        Task { await streamToStop?.stop() }

        // Fail any in-flight photo continuation.
        photoContinuation?.resume(throwing: GlassesServiceError.photoCaptureFailed("Disconnected"))
        photoContinuation = nil

        latestVideoFrame = nil
    }

    // MARK: - Private: audio (Bluetooth HFP via AVAudioSession + AVAudioEngine)

    /// Configures AVAudioSession to receive microphone input from the glasses.
    ///
    /// The Ray-Ban Meta glasses appear as a standard Bluetooth HFP device in iOS.
    /// `.allowBluetooth` routes the mic input through them when they are the active
    /// Bluetooth audio source.
    private func configureAudioSession() throws {
        let avAudioSession = AVAudioSession.sharedInstance()
        try avAudioSession.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.allowBluetooth, .defaultToSpeaker]
        )
        // 16 kHz is the sample rate most ASR engines (including SFSpeechRecognizer) prefer.
        try avAudioSession.setPreferredSampleRate(16_000)
        try avAudioSession.setActive(true)
    }

    /// Installs an AVAudioEngine input tap and forwards 16-bit PCM buffers as AudioChunks.
    private func startAudioEngine(continuation: AsyncStream<AudioChunk>.Continuation) throws {
        let engine = AVAudioEngine()
        audioEngine = engine

        let inputNode = engine.inputNode

        // Request 16-bit, 16 kHz, mono PCM. AVAudioEngine resamples automatically if the
        // Bluetooth device reports a different hardware sample rate.
        let captureFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ) ?? inputNode.outputFormat(forBus: 0)

        // 1 600 frames ≈ 100 ms at 16 kHz.
        let bufferSize: AVAudioFrameCount = 1_600

        inputNode.installTap(
            onBus: 0,
            bufferSize: bufferSize,
            format: captureFormat
        ) { buffer, _ in
            guard let channelData = buffer.int16ChannelData?[0] else { return }
            let frameCount = Int(buffer.frameLength)
            let pcmData = Data(
                bytes: channelData,
                count: frameCount * MemoryLayout<Int16>.size
            )
            continuation.yield(AudioChunk(
                data: pcmData,
                timestamp: Date(),
                durationMs: Int(Double(frameCount) / 16.0)  // 16 frames per ms at 16 kHz
            ))
        }

        engine.prepare()
        try engine.start()
    }
}

// MARK: - Mock Implementation

/// Simulates glasses behaviour so the entire app can be built and run without hardware.
///
/// ## Audio
/// Yields 100 ms of near-silent 16 kHz mono PCM every 100 ms so the speech-to-text
/// pipeline can be exercised. For more realistic testing, replace `makeSimulatedAudioData()`
/// with a real PCM file read from the app bundle.
///
/// ## Photos
/// Tries to load an image named **"MockExamFinding"** from the asset catalog.
/// To use a realistic test image, add a JPEG or PNG with that name to `Assets.xcassets`.
/// Falls back to a generated teal checkerboard placeholder when the asset is absent.
@Observable
class MockGlassesService: GlassesServiceProtocol {

    // ── Observable state ─────────────────────────────────────────────────────────

    private(set) var connectionStatus: ConnectionStatus = .disconnected
    private(set) var discoveredDevices: [GlassesDevice] = []

    // ── Private state ─────────────────────────────────────────────────────────────

    private var audioContinuation: AsyncStream<AudioChunk>.Continuation?
    private var audioTask: Task<Void, Never>?

    /// Long-lived hardware event stream. Created in `init()`; never replaced.
    private(set) var hardwareEvents: AsyncStream<GlassesHardwareEvent>
    private var hardwareEventContinuation: AsyncStream<GlassesHardwareEvent>.Continuation?

    /// Background task that emits simulated hardware events on a fixed schedule.
    /// Started in `connect(to:)`, cancelled in `disconnect()`.
    private var hardwareEventTask: Task<Void, Never>?

    /// Canned device list surfaced after `startDiscovery()` completes its simulated scan.
    private let simulatedDevices: [GlassesDevice] = [
        GlassesDevice(id: UUID(), name: "Ray-Ban Meta Studio (Mock)", signalStrength: -52),
        GlassesDevice(id: UUID(), name: "Ray-Ban Meta Wayfarer (Mock)", signalStrength: -71),
    ]

    // ── Lifecycle ─────────────────────────────────────────────────────────────────

    init() {
        let (hwStream, hwContinuation) = AsyncStream.makeStream(of: GlassesHardwareEvent.self)
        self.hardwareEvents = hwStream
        self.hardwareEventContinuation = hwContinuation
    }

    // ── GlassesServiceProtocol ────────────────────────────────────────────────────

    func startDiscovery() async throws {
        discoveredDevices = []
        connectionStatus = .scanning
        // Simulate the 1–3 s a real Bluetooth scan typically takes.
        try await Task.sleep(for: .seconds(2))
        discoveredDevices = simulatedDevices
    }

    func connect(to device: GlassesDevice) async throws {
        connectionStatus = .connecting
        // Simulate SDK handshake latency.
        try await Task.sleep(for: .milliseconds(900))
        connectionStatus = .connected
        // Begin emitting simulated hardware events so the encounter flow can be
        // exercised end-to-end in the simulator without physical glasses.
        startHardwareEventSimulation()
    }

    func disconnect() {
        stopAudioCapture()
        stopHardwareEventSimulation()
        discoveredDevices = []
        connectionStatus = .disconnected
    }

    func startAudioCapture() async throws -> AsyncStream<AudioChunk> {
        guard connectionStatus == .connected else {
            throw GlassesServiceError.notConnected
        }
        stopAudioCapture()

        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        audioContinuation = continuation

        audioTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self {
                    continuation.yield(AudioChunk(
                        data: self.makeSimulatedAudioData(),
                        timestamp: Date(),
                        durationMs: 100
                    ))
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            continuation.finish()
        }

        return stream
    }

    func stopAudioCapture() {
        audioTask?.cancel()
        audioTask = nil
        audioContinuation?.finish()
        audioContinuation = nil
    }

    func capturePhoto() async throws -> Data {
        guard connectionStatus == .connected else {
            throw GlassesServiceError.notConnected
        }
        // Simulate the shutter-to-transfer delay.
        try await Task.sleep(for: .milliseconds(500))

        if let image = UIImage(named: "MockExamFinding"),
           let jpeg = image.jpegData(compressionQuality: 0.8) {
            return jpeg
        }
        return makePlaceholderImageData()
    }

    // ── Hardware event simulation ─────────────────────────────────────────────────

    /// Starts a repeating task that emits simulated hardware events.
    ///
    /// ## Simulated schedule (repeats indefinitely)
    /// | Elapsed | Event                | Default action         |
    /// |---------|----------------------|------------------------|
    /// | +8 s    | cameraButtonPressed  | captureExamFinding     |
    /// | +16 s   | sideDoubleTap        | captureExamFinding     |
    /// | +24 s   | cameraButtonPressed  | captureExamFinding     |
    /// | +32 s   | sideSingleTap        | startRecording         |
    /// | +40 s   | longPressSide        | stopRecording          |
    /// | +48 s   | voiceCommandDetected | captureExamFinding     |
    private func startHardwareEventSimulation() {
        stopHardwareEventSimulation()

        let eventCycle: [GlassesHardwareEvent] = [
            .cameraButtonPressed,
            .sideDoubleTap,
            .cameraButtonPressed,
            .sideSingleTap,
            .longPressSide,
            .voiceCommandDetected("capture finding"),
        ]
        let intervalSeconds: Double = 8

        hardwareEventTask = Task { [weak self] in
            var index = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(intervalSeconds))
                guard let self, !Task.isCancelled else { break }
                hardwareEventContinuation?.yield(eventCycle[index])
                index = (index + 1) % eventCycle.count
            }
        }
    }

    private func stopHardwareEventSimulation() {
        hardwareEventTask?.cancel()
        hardwareEventTask = nil
    }

    // ── Private helpers ───────────────────────────────────────────────────────────

    private func makeSimulatedAudioData() -> Data {
        let sampleCount = 1_600
        var samples = [Int16](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount { samples[i] = Int16.random(in: -12...12) }
        return samples.withUnsafeBytes { Data($0) }
    }

    private func makePlaceholderImageData() -> Data {
        let size = CGSize(width: 200, height: 200)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.jpegData(withCompressionQuality: 0.8) { ctx in
            UIColor.systemTeal.withAlphaComponent(0.55).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.white.withAlphaComponent(0.65).setFill()
            let tile: CGFloat = 50
            for row in 0..<4 {
                for col in 0..<4 where (row + col).isMultiple(of: 2) {
                    ctx.fill(CGRect(x: CGFloat(col) * tile, y: CGFloat(row) * tile,
                                   width: tile, height: tile))
                }
            }
        }
    }
}
