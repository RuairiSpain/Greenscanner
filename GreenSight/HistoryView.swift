import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            Group {
                if model.records.isEmpty {
                    ContentUnavailableView("No saved reads", systemImage: "clock.arrow.circlepath",
                                           description: Text("Completed device scans are kept on this iPhone."))
                } else {
                    List {
                        ForEach(model.records) { record in
                            NavigationLink {
                                HistoryDetailView(record: record)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(record.createdAt, format: .dateTime.day().month().hour().minute())
                                            .font(.headline)
                                        Spacer()
                                        Image(systemName: record.solution.holed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                            .foregroundStyle(record.solution.holed ? .green : .orange)
                                    }
                                    HStack {
                                        Label(String(format: "%.1f m", record.distanceMetres), systemImage: "ruler")
                                        Spacer()
                                        Text("Stimp \(record.stimpFeet, specifier: "%.1f")")
                                        Spacer()
                                        Text(record.coverage, format: .percent.precision(.fractionLength(0)))
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete(perform: model.deleteRecords)
                    }
                }
            }
            .navigationTitle("Read history")
        }
    }
}

struct HistoryDetailView: View {
    let record: ScanRecord

    var body: some View {
        List {
            Section("Recommended putt") {
                LabeledContent("Aim", value: String(format: "%.1f°", record.solution.launchAngleDegrees))
                LabeledContent("Aim offset", value: String(format: "%.0f cm", record.solution.aimOffsetCentimetres))
                LabeledContent("Start speed", value: String(format: "%.2f m/s", record.solution.launchSpeedMetresPerSecond))
                LabeledContent("Closest approach", value: String(format: "%.1f cm", record.solution.closestDistanceMetres * 100))
                LabeledContent("Confidence", value: record.solution.confidence.formatted(.percent.precision(.fractionLength(0))))
            }
            Section("Capture") {
                LabeledContent("Distance", value: String(format: "%.2f m", record.distanceMetres))
                LabeledContent("Coverage", value: record.coverage.formatted(.percent.precision(.fractionLength(0))))
                LabeledContent("Grid cells", value: "\(record.surface.cells.count)")
                LabeledContent("Green speed", value: String(format: "Stimp %.1f", record.stimpFeet))
            }
            Section("Surface") { HeatMapView(snapshot: record.surface).listRowInsets(EdgeInsets()) }
        }
        .navigationTitle(record.createdAt.formatted(date: .abbreviated, time: .shortened))
    }
}
