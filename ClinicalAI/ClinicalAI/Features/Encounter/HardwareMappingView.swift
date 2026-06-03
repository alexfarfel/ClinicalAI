// HardwareMappingView.swift
// ClinicalAI — Hardware Button Mapping Settings
//
// Allows the physician to reassign which glasses gesture triggers which app action.
// Changes are saved to UserDefaults immediately on each picker change — no explicit
// Save button is needed. The next hardware event will use the new mapping.
//
// Opened via the gear icon in the top-right corner of EncounterView.

import SwiftUI

struct HardwareMappingView: View {

    /// Loaded from UserDefaults on appear; saved back on every change.
    @State private var mapping = HardwareActionMapping.load()

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                assignmentsSection
                resetSection
                aboutSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Button Mapping")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            // Auto-save on every picker change.
            .onChange(of: mapping) { _, _ in mapping.save() }
        }
    }

    // MARK: - Sections

    private var assignmentsSection: some View {
        Section {
            mappingRow(
                title:       "Camera Button",
                description: "Dedicated camera button on the frame",
                icon:        "camera.circle.fill",
                binding:     $mapping.cameraButtonPressed
            )
            mappingRow(
                title:       "Double Tap Side",
                description: "Tap the side arm twice quickly",
                icon:        "hand.tap.fill",
                binding:     $mapping.sideDoubleTap
            )
            mappingRow(
                title:       "Single Tap Side",
                description: "Tap the side arm once",
                icon:        "hand.point.right.fill",
                binding:     $mapping.sideSingleTap
            )
            mappingRow(
                title:       "Long Press Side",
                description: "Hold the side arm down",
                icon:        "hand.tap",
                binding:     $mapping.longPressSide
            )
            mappingRow(
                title:       "Voice Command",
                description: "Any recognised voice phrase",
                icon:        "mic.circle.fill",
                binding:     $mapping.voiceCommandDetected
            )
        } header: {
            Text("Button & Gesture Assignments")
        } footer: {
            Text("Changes take effect immediately — no need to reconnect your glasses.")
        }
    }

    private var resetSection: some View {
        Section {
            Button(role: .destructive) {
                withAnimation {
                    mapping = .default
                    mapping.save()
                }
            } label: {
                Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
            }
        }
    }

    private var aboutSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("Default mapping", systemImage: "info.circle")
                    .font(.subheadline.weight(.medium))
                ForEach(defaultSummaryRows, id: \.self) { row in
                    Text(row)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var defaultSummaryRows: [String] {
        [
            "• Camera button / Double tap  →  Capture Exam Finding",
            "• Single tap  →  Start Recording",
            "• Long press  →  Stop Recording",
            "• Voice command  →  Capture Exam Finding",
        ]
    }

    // MARK: - Row builder

    @ViewBuilder
    private func mappingRow(
        title: String,
        description: String,
        icon: String,
        binding: Binding<GlassesAction>
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 30, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("", selection: binding) {
                ForEach(GlassesAction.allCases, id: \.self) { action in
                    Text(action.displayName).tag(action)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Preview

#Preview {
    HardwareMappingView()
}
