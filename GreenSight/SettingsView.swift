import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

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
                Section("Capture") {
                    Toggle("Automatic ball and cup suggestion", isOn: $model.autoDetection)
                    Toggle("Diagnostic overlay", isOn: $model.showDiagnostics)
                    Text("Auto-detection is a geometric suggestion. Tap the object manually if it selects the wrong contour.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    LabeledContent("Version", value: "1.1 (2)")
                    LabeledContent("Grid", value: "30 mm")
                    LabeledContent("Physics", value: "Rolling sphere + Stimp drag")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
