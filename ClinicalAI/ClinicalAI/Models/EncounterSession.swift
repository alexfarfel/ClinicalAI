// EncounterSession.swift
// ClinicalAI — Encounter Session Data Model
//
// Represents one patient encounter from start to finish. Created when the physician
// taps "Start Encounter" and finalised when they tap "End Encounter".
//
// Privacy rule: raw image Data inside ExamFinding must be cleared (set to nil) as soon
// as the SOAP note has been successfully generated. Only annotation text is retained.

import Foundation

// MARK: - Encounter Status

/// The lifecycle state of an encounter session.
///
/// Transitions in order: recording → processing → complete.
/// A session should never move backwards through these states.
enum EncounterStatus: String, Codable, Equatable {
    /// Audio recording is active; the encounter is in progress.
    case recording
    /// The physician has ended the encounter; the app is sending data to Claude.
    case processing
    /// Claude has returned the SOAP note; the session is closed.
    case complete
}

// MARK: - TimestampedAudio

/// A short audio segment with its position in the encounter timeline and its transcription.
///
/// Audio is captured in segments (rather than one long file) so that:
///   1. Individual segments can be discarded if the physician pauses.
///   2. Memory pressure stays low on the device.
///
/// The raw audio bytes are processed by the on-device speech-to-text engine and then
/// discarded immediately — only the transcription text is stored here.
struct TimestampedAudio: Codable, Equatable {
    /// Offset in seconds from `EncounterSession.startTime` when this segment began.
    let timestamp: TimeInterval

    /// How many seconds of audio this segment covers.
    let durationSeconds: Double

    /// Text produced by speech-to-text. Empty string while transcription is pending.
    var transcription: String
}

// MARK: - BodySystem

/// The body system a physical exam finding is associated with.
///
/// Used to group findings under the correct heading in the SOAP note's Physical Exam section.
/// `other` covers any finding that does not fit a named system.
enum BodySystem: String, Codable, Equatable, CaseIterable {
    case general
    case cardiovascular
    case pulmonary
    case abdominal
    case neurological
    case musculoskeletal
    case skin
    case other

    /// A human-readable label for display in the UI.
    var displayName: String {
        switch self {
        case .general:          return "General"
        case .cardiovascular:   return "Cardiovascular"
        case .pulmonary:        return "Pulmonary"
        case .abdominal:        return "Abdominal"
        case .neurological:     return "Neurological"
        case .musculoskeletal:  return "Musculoskeletal"
        case .skin:             return "Skin"
        case .other:            return "Other"
        }
    }
}

// MARK: - ExamFinding

/// A single physical exam finding captured during an encounter.
///
/// The physician taps "Capture Finding"; the glasses take a photo and the physician
/// adds a brief spoken or typed annotation (e.g., "3 cm erythematous patch, right forearm").
///
/// Privacy rule: `image` must be set to `nil` as soon as the SOAP note is successfully
/// generated. See `EncounterSession.clearRawImageData()`.
struct ExamFinding: Identifiable, Codable, Equatable {
    /// Unique identifier for this finding.
    let id: UUID

    /// Offset in seconds from `EncounterSession.startTime` when this finding was captured.
    let timestamp: TimeInterval

    /// Raw image bytes (JPEG or PNG) from the glasses camera.
    /// Set to `nil` after note generation to comply with the patient-privacy rule.
    var image: Data?

    /// Brief physician annotation describing the finding (e.g., "wheezing, bilateral lower lobes").
    var annotation: String

    /// The body system this finding belongs to — used to place it in the correct SOAP section.
    var bodySystem: BodySystem
}

// MARK: - EncounterSession

/// The complete record of a single patient encounter from first tap to note generation.
///
/// `EncounterSession` is the central object that flows through the entire physician workflow:
///
///   1. Created (status: `.recording`) when the physician taps "Start Encounter".
///   2. `audioSegments` are appended continuously as speech-to-text produces results.
///   3. `examFindings` are appended when the physician taps "Capture Finding".
///   4. Status changes to `.processing` when the physician taps "End Encounter".
///   5. After Claude returns the SOAP note, status becomes `.complete` and image data
///      is cleared from all findings via `clearRawImageData()`.
struct EncounterSession: Identifiable, Codable, Equatable {
    /// Unique identifier — also stored on the resulting `ClinicalNote` to link them.
    let id: UUID

    /// Wall-clock time when the physician tapped "Start Encounter".
    let startTime: Date

    /// Wall-clock time when the physician tapped "End Encounter". `nil` while recording.
    var endTime: Date?

    /// Ordered list of audio segments captured during the encounter.
    var audioSegments: [TimestampedAudio]

    /// Physical exam findings captured during the encounter, in the order they were taken.
    var examFindings: [ExamFinding]

    /// The current lifecycle state of this session.
    var status: EncounterStatus

    // MARK: Derived helpers

    /// The full encounter transcript, assembled by joining all segment transcriptions
    /// in chronological order. This is the text sent to Claude as the conversation portion
    /// of the note-generation prompt.
    var fullTranscript: String {
        audioSegments
            .sorted { $0.timestamp < $1.timestamp }
            .map(\.transcription)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Total encounter duration in seconds. Returns `nil` if the encounter has not ended.
    var durationSeconds: TimeInterval? {
        guard let endTime else { return nil }
        return endTime.timeIntervalSince(startTime)
    }

    // MARK: Privacy

    /// Removes all raw image data from exam findings.
    ///
    /// Call this immediately after the SOAP note has been successfully generated and saved.
    /// Annotation text is preserved so the note remains clinically meaningful.
    mutating func clearRawImageData() {
        for index in examFindings.indices {
            examFindings[index].image = nil
        }
    }
}
