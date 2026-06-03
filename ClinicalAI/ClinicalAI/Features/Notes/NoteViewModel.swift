// NoteViewModel.swift
// ClinicalAI — Note Business Logic
//
// Drives the NoteView. Currently holds the note and tracks whether the physician
// has made any edits. Full responsibilities (encryption, persistence, EHR export)
// will be implemented in a future prompt.

import Foundation

@Observable
@MainActor
final class NoteViewModel {

    // MARK: - State

    /// The SOAP note being reviewed. All five fields are independently editable.
    var note: ClinicalNote

    /// True once the physician has modified any field after the AI generated the note.
    /// Shown in the UI so the physician knows which notes they have personally reviewed.
    var isDirty: Bool { note.isEdited }

    // MARK: - Init

    init(note: ClinicalNote) {
        self.note = note
    }

    // MARK: - Editing

    /// Marks the note as physician-reviewed. Call after any field edit.
    func markEdited() {
        note.isEdited = true
    }

    /// Returns the note formatted as plain text for copy-paste into an EHR system.
    var plainTextForEHR: String {
        note.plainTextForEHR
    }

    // TODO: Implement encrypt(_ note:) via EncryptionService before persisting to disk.
    // TODO: Implement save() to write the encrypted note to the app's documents directory.
    // TODO: Implement delete() to purge the note when the physician dismisses without saving.
}
