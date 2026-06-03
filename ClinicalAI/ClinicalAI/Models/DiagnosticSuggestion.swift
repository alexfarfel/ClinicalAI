// DiagnosticSuggestion.swift
// ClinicalAI — Diagnostic AI Partner Models (Phase 2)
//
// Represents a structured response from Claude's real-time diagnostic consultation feature.
// Produced each time the physician taps "Consult AI" during an active encounter.
//
// Privacy / persistence rule: DiagnosticSuggestion objects are held in memory only for
// the duration of the encounter. They are NEVER persisted to disk. Only the ClinicalNote
// is the permanent record. When the encounter ends, all DiagnosticSuggestion instances
// should be discarded.

import Foundation

// MARK: - DiagnosisLikelihood

/// How confident Claude is that a diagnosis applies to the current clinical presentation.
///
/// Maps to the three standard probability tiers used in clinical differential-diagnosis
/// teaching (high, moderate, low) rather than numeric percentages, which would imply
/// more precision than AI-generated rankings can reliably support.
enum DiagnosisLikelihood: String, Codable, Equatable, CaseIterable {
    /// Strong clinical fit; should be the working diagnosis until ruled out.
    case high
    /// Plausible given the presentation, but not the leading explanation.
    case moderate
    /// Possible, but requires more information or testing before it can be elevated.
    case low

    /// A human-readable label for display in the UI (e.g., badge colour or rank label).
    var displayName: String {
        switch self {
        case .high:     return "High"
        case .moderate: return "Moderate"
        case .low:      return "Low"
        }
    }
}

// MARK: - Diagnosis

/// A single entry in the differential diagnosis list produced by Claude.
///
/// Each `Diagnosis` represents one condition Claude considers relevant to the patient's
/// current presentation, ordered by likelihood and accompanied by a plain-language rationale
/// so the physician can quickly evaluate Claude's reasoning without leaving the encounter.
struct Diagnosis: Identifiable, Codable, Equatable {
    /// Unique identifier — used to update or highlight individual diagnoses in the UI.
    let id: UUID

    /// The medical name of the condition.
    ///
    /// Example: "Community-acquired pneumonia" or "Pulmonary embolism".
    let name: String

    /// Claude's assessment of how likely this diagnosis is given the current clinical picture.
    let likelihood: DiagnosisLikelihood

    /// The ICD-10-CM code for this condition, if Claude was able to identify one.
    ///
    /// Format: one letter followed by two digits, optional decimal and further digits
    /// (e.g., "J18.9" for unspecified pneumonia).
    /// `nil` when Claude could not confidently map the condition to a specific code.
    let icdCode: String?

    /// Plain-language explanation of why this diagnosis fits the current presentation.
    ///
    /// Displayed beneath the diagnosis name so the physician can quickly evaluate
    /// Claude's logic and decide whether to pursue or dismiss this differential.
    let rationale: String
}

// MARK: - DiagnosticSuggestion

/// A structured response from the AI diagnostic partner for a given moment in the encounter.
///
/// Packages Claude's differential diagnosis list together with actionable clinical
/// recommendations so the physician gets everything they need in a single response object.
///
/// Typical usage:
///   1. Physician taps "Consult AI" during an active encounter.
///   2. `DiagnosticViewModel` sends the current transcript + findings to Claude.
///   3. Claude returns JSON that is decoded into a `DiagnosticSuggestion`.
///   4. The view displays `differentialDiagnoses`, `suggestedExamManeuvers`, and
///      `recommendedTests` as organised lists, with `reasoning` in an expandable section.
///
/// This object is **not** part of the permanent medical record and must not be persisted.
struct DiagnosticSuggestion: Identifiable, Codable, Equatable {
    /// Unique identifier — used to track which suggestion is currently displayed in the UI.
    let id: UUID

    /// The ranked list of conditions Claude considers most likely given the current presentation.
    ///
    /// Ordered from most likely to least likely. The physician should evaluate the high-
    /// likelihood entries first, but all entries are worth reviewing for completeness.
    let differentialDiagnoses: [Diagnosis]

    /// Physical examination maneuvers Claude recommends to distinguish between the differentials.
    ///
    /// Described as plain strings so they can be read aloud or displayed in a compact list
    /// without requiring any additional data model.
    ///
    /// Examples: "Murphy's sign", "straight-leg raise", "Romberg test", "Kernig's sign".
    let suggestedExamManeuvers: [String]

    /// Laboratory or imaging tests Claude recommends to narrow the differential.
    ///
    /// Examples: "CBC with differential", "Chest X-ray PA and lateral", "D-dimer", "BMP".
    let recommendedTests: [String]

    /// Claude's narrative explanation of its overall clinical reasoning.
    ///
    /// Describes how the differential was formed, which features of the presentation are most
    /// discriminating, and what additional information would most change the assessment.
    /// Displayed in an expandable "Reasoning" section so physicians who want the detail can
    /// access it without cluttering the primary view.
    let reasoning: String
}
