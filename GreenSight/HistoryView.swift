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
                                        VStack(alignment: .leading, spacing: 2) {
                                            if let label = record.label {
                                                Text(label).font(.headline)
                                            }
                                            Text(record.createdAt, format: .dateTime.day().month().hour().minute())
                                                .font(record.label == nil ? .headline : .caption)
                                        }
                                        Spacer()
                                        Image(systemName: record.solution.holed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                            .foregroundStyle(record.solution.holed ? .green : .orange)
                                    }
                                    HStack {
                                        Label(model.units.distance(record.distanceMetres), systemImage: "ruler")
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
    @EnvironmentObject private var model: AppModel
    let record: ScanRecord
    @State private var label = ""

    var body: some View {
        List {
            Section("Course / hole") {
                TextField("e.g. 7th green, back-left pin", text: $label)
                    .onSubmit { model.setLabel(label, for: record.id) }
                    .submitLabel(.done)
            }
            Section("Recommended putt") {
                LabeledContent("Aim", value: String(format: "%.1f°", record.solution.launchAngleDegrees))
                LabeledContent("Aim offset", value: model.units.shortLength(abs(record.solution.aimOffsetCentimetres) / 100)
                               + (record.solution.aimOffsetCentimetres > 0 ? " right" : " left"))
                LabeledContent("Start speed", value: model.units.speed(record.solution.launchSpeedMetresPerSecond))
                LabeledContent("Closest approach", value: model.units.shortLength(record.solution.closestDistanceMetres))
                if let chance = record.solution.holeProbability {
                    LabeledContent("Holes out", value: chance.formatted(.percent.precision(.fractionLength(0))))
                }
                LabeledContent("Confidence", value: record.solution.confidence.formatted(.percent.precision(.fractionLength(0))))
            }
            Section("Capture") {
                LabeledContent("Distance", value: model.units.distance(record.distanceMetres))
                LabeledContent("Coverage", value: record.coverage.formatted(.percent.precision(.fractionLength(0))))
                LabeledContent("Grid cells", value: "\(record.surface.cells.count)")
                LabeledContent("Green speed", value: String(format: "Stimp %.1f", record.stimpFeet))
            }
            Section("Surface") { HeatMapView(snapshot: record.surface).listRowInsets(EdgeInsets()) }
        }
        .navigationTitle(record.createdAt.formatted(date: .abbreviated, time: .shortened))
        .onAppear { label = record.label ?? "" }
        .onDisappear { model.setLabel(label, for: record.id) }
    }
}
