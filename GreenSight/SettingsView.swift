import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var mapModel: MapModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Green speed") {
                    HStack {
                        Text("Stimp")
                        Slider(value: $model.stimpFeet, in: 7...14, step: 0.5)
                        Text(model.stimpFeet, specifier: "%.1f")
                            .monospacedDigit()
                            .frame(width: 34)
                    }
                    Text("Set the measured or estimated Stimpmeter value before calculating. Line and speed are coupled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Units") {
                    Picker("Units", selection: $model.units) {
                        ForEach(UnitSystem.allCases) { Text($0.label).tag($0) }
                    }
                }
                Section("Capture") {
                    Toggle("Automatic ball and cup suggestion", isOn: $model.autoDetection)
                    Toggle("Diagnostic overlay", isOn: $model.showDiagnostics)
                    Text("Auto-detection is a geometric suggestion. Tap the object manually if it selects the wrong contour.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Picker("Depth source", selection: $mapModel.depthSource) {
                        ForEach(DepthSource.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Save ARKit world map for resuming", isOn: $mapModel.useWorldMap)
                    Toggle("Capture a top-down colour image", isOn: $mapModel.capturePhoto)
                    Toggle("Suggest the cup automatically", isOn: $mapModel.autoCupDetection)
                } header: {
                    Text("Map a Green")
                } footer: {
                    Text("Smoothed depth is filtered over time and may be quieter but lag behind movement. The choice is saved with each scan so you can compare them in the validation report. Saving the world map lets an interrupted scan be resumed in the same place, but the files are larger and each save takes more work; with it off, an interrupted scan can only be saved as captured. The colour image keeps only ground colours at 10 cm resolution, nothing above the ground and no photos. Automatic cup suggestions always ask for confirmation.")
                }
                Section("Measurement limits") {
                    Label("Requires an iPhone or iPad exposing ARKit scene depth.", systemImage: "sensor.tag.radiowaves.forward")
                    Label("Rejects limited-tracking and low-confidence depth samples.", systemImage: "checkmark.shield")
                    Label("Surface accuracy varies with range, motion, turf and lighting.", systemImage: "exclamationmark.triangle")
                }
                Section("Use") {
                    Text("GreenSight is an engineering test build, not a validated surveying instrument. Verify local competition rules before use during a stipulated round. Never walk on another player’s line or delay play.")
                }
                Section("Privacy") {
                    Text("Camera and depth frames are processed on-device. Saved reads contain reconstructed surface cells and calculated paths—not photos or video.")
                }
                Section("About") {
                    LabeledContent("Version", value: "1.11 (12)")
                    LabeledContent("Grid", value: "30 mm")
                    LabeledContent("Physics", value: "Rolling sphere + Stimp drag")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
