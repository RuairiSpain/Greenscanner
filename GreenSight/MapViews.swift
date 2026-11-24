import SwiftUI
import RealityKit
import UniformTypeIdentifiers
import simd

// MARK: Home

struct MapHomeView: View {
    @EnvironmentObject private var model: MapModel
    @State private var importing = false

    private struct CourseGroup: Identifiable {
        let course: String
        let records: [GreenMapRecord]
        var id: String { course }
    }

    private struct MergeableHole: Identifiable {
        let hole: Int
        let count: Int
        var id: Int { hole }
    }

    private var groupedCourses: [CourseGroup] {
        Dictionary(grouping: model.records, by: \.courseName)
            .map { CourseGroup(course: $0.key, records: $0.value.sorted { $0.holeNumber < $1.holeNumber }) }
            .sorted { $0.course.localizedCaseInsensitiveCompare($1.course) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                if let draft = model.draft {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(draft.courseName) · Hole \(draft.holeNumber)").font(.headline)
                            HStack(spacing: 4) {
                                Text(draft.phase == "edge" ? "Edge marking" : "\(draft.coverage.formatted(.percent.precision(.fractionLength(0)))) scanned")
                                Text("· saved")
                                Text(draft.savedAt, style: .relative)
                                Text("ago")
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        if draft.hasWorldMap {
                            Button { model.resumeDraft() } label: { Label("Resume scan", systemImage: "play.fill") }
                        }
                        if draft.hasScanData {
                            Button { model.recoverDraftAsGreen() } label: { Label("Save what was captured", systemImage: "tray.and.arrow.down") }
                        }
                        Button(role: .destructive) { model.discardDraft() } label: { Label("Discard", systemImage: "trash") }
                    } header: {
                        Text("Unfinished scan")
                    } footer: {
                        Text("Resuming needs you to stand where you were scanning so the camera can recognise the spot. Grass has few features, so it may not relocalise; saving what was captured always works.")
                    }
                    .disabled(model.draftBusy)
                }
                Section {
                    TextField("Course name", text: $model.courseName)
                        .textInputAutocapitalization(.words)
                    if let suggestion = model.nearbyCourseSuggestion, suggestion != model.courseName {
                        Button("Use nearby course: \(suggestion)") { select(course: suggestion) }
                    }
                    if !model.courseNames.isEmpty {
                        Menu("Choose a saved course") {
                            ForEach(model.courseNames, id: \.self) { name in
                                Button(name) { select(course: name) }
                            }
                        }
                    }
                    Stepper("Hole \(model.holeNumber)", value: $model.holeNumber, in: 1...18)
                    Button {
                        model.beginMapping()
                    } label: {
                        Label("Begin mapping", systemImage: "map")
                            .fontWeight(.semibold)
                    }
                    .disabled(model.courseName.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let error = model.setupError {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                } header: {
                    Text("Map a green")
                } footer: {
                    Text("Walk the edge of the green first, then walk the inside. Only map where the course allows it.")
                }

                ForEach(groupedCourses) { group in
                    Section("\(group.course) · \(Set(group.records.map(\.holeNumber)).count) of 18 holes") {
                        ForEach(group.records) { record in
                            NavigationLink {
                                GreenDetailView(record: record)
                            } label: { row(record) }
                        }
                        .onDelete { offsets in model.delete(offsets.map { group.records[$0].id }) }
                        ForEach(model.mergeableHoles(course: group.course).map { MergeableHole(hole: $0.hole, count: $0.count) }) { item in
                            Button {
                                model.startMerge(course: group.course, hole: item.hole)
                            } label: {
                                Label("Merge \(item.count) scans of hole \(item.hole)", systemImage: "square.on.square")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Map a Green")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { importing = true } label: { Label("Import", systemImage: "square.and.arrow.down") }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                if case .success(let url) = result { model.importGreen(from: url) }
            }
            .alert("Scan recovery", isPresented: Binding(get: { model.recoveryMessage != nil },
                                                          set: { if !$0 { model.recoveryMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(model.recoveryMessage ?? "") }
            .alert("Import failed", isPresented: Binding(get: { model.importError != nil },
                                                          set: { if !$0 { model.importError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(model.importError ?? "") }
            .sheet(isPresented: Binding(get: { model.mergeStatus != nil },
                                        set: { if !$0 { model.dismissMerge() } })) {
                MergeSheet().environmentObject(model)
            }
            .onAppear { model.location.start() }
            .fullScreenCover(isPresented: $model.isMapping) {
                MapScanScreen().environmentObject(model)
            }
        }
    }

    private func select(course: String) {
        model.courseName = course
        model.holeNumber = model.nextUnmappedHole(for: course)
    }

    private func row(_ record: GreenMapRecord) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Hole \(record.holeNumber)").font(.headline)
                Text(record.createdAt, format: .dateTime.day().month().year())
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(record.coverage, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                Text(record.isPartial ? "Partial" : "Complete")
                    .font(.caption)
                    .foregroundStyle(record.isPartial ? .orange : .green)
            }
        }
    }
}

// MARK: Detail

struct GreenDetailView: View {
    @EnvironmentObject private var model: MapModel
    let record: GreenMapRecord
    @State private var exportURL: URL?

    var body: some View {
        List {
            Section { MapSlopeView(record: record).listRowInsets(EdgeInsets()) }
            Section("Scan") {
                LabeledContent("Coverage", value: record.coverage.formatted(.percent.precision(.fractionLength(0))))
                LabeledContent("Quality", value: record.qualityScore.formatted(.percent.precision(.fractionLength(0))))
                if let drift = record.driftMillimetres {
                    LabeledContent("Height drift between passes", value: String(format: "%.0f mm", drift))
                }
                if let residual = record.residualMillimetres {
                    LabeledContent("After correction", value: String(format: "%.0f mm", residual))
                }
                if let correction = record.maxCorrectionMillimetres {
                    LabeledContent("Largest correction", value: String(format: "%.0f mm", correction))
                }
                if let zones = record.zoneCount {
                    LabeledContent("Zones", value: "\(zones)" + ((record.unlinkedZones ?? 0) > 0 ? " (\(record.unlinkedZones ?? 0) unlinked)" : ""))
                }
                LabeledContent("Tracking losses", value: "\(record.trackingLossCount)")
                LabeledContent("Cells", value: "\(record.cells.count)")
                LabeledContent("North-aligned", value: record.headingAligned ? "Yes" : "No")
                if let count = record.sourceScanCount {
                    LabeledContent("Merged from", value: "\(count) scans")
                }
            }
            ValidationSection(record: record)
            if let url = exportURL {
                Section { ShareLink(item: url) { Label("Export green file", systemImage: "square.and.arrow.up") } }
            }
        }
        .navigationTitle("\(record.courseName) \(record.holeNumber)")
        .task { exportURL = await model.prepareExport(record) }
    }
}

// MARK: Merge sheet

struct MergeSheet: View {
    @EnvironmentObject private var model: MapModel
    @State private var removeSources = false

    var body: some View {
        NavigationStack {
            Group {
                switch model.mergeStatus {
                case .working, .none:
                    ProgressView("Aligning scans…").frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    ContentUnavailableView("Could not merge", systemImage: "exclamationmark.triangle",
                                           description: Text(message))
                case .ready(let result):
                    List {
                        Section { MapSlopeView(record: result.record).listRowInsets(EdgeInsets()) }
                        Section("Result") {
                            LabeledContent("Scans combined", value: "\(result.usedCount)")
                            LabeledContent("Coverage", value: result.record.coverage.formatted(.percent.precision(.fractionLength(0))))
                            LabeledContent("Quality", value: result.record.qualityScore.formatted(.percent.precision(.fractionLength(0))))
                            LabeledContent("Outline overlap", value: result.minimumOverlap.formatted(.percent.precision(.fractionLength(0))))
                            if let residual = result.residualMillimetres {
                                LabeledContent("Scan disagreement", value: String(format: "%.0f mm", residual))
                            }
                        }
                        if !result.skipped.isEmpty {
                            Section("Not used") { ForEach(result.skipped, id: \.self) { Text($0).font(.caption) } }
                        }
                        Section {
                            Toggle("Delete the \(result.usedCount) source scans after saving", isOn: $removeSources)
                            Button("Save merged green") { model.saveMerged(result, removeSources: removeSources) }
                                .fontWeight(.semibold)
                        }
                    }
                }
            }
            .navigationTitle("Merge scans")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.dismissMerge() } }
            }
        }
    }
}

// MARK: Validation

/// Accuracy check for a scan of a surface with a known grade (level floor or a measured board).
struct ValidationSection: View {
    let record: GreenMapRecord
    @State private var knownSurface = false
    @State private var expectedText = "0"

    private var expected: Double? {
        guard knownSurface else { return nil }
        return Double(expectedText.replacingOccurrences(of: ",", with: "."))
    }

    var body: some View {
        Section {
            Toggle("This was a surface with a known grade", isOn: $knownSurface)
            if knownSurface {
                HStack {
                    Text("Known grade (%)")
                    Spacer()
                    TextField("0", text: $expectedText)
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }
            }
            if let report = ValidationReport.make(from: record, expectedGradePercent: expected) {
                LabeledContent("Fitted plane grade", value: String(format: "%.2f%%", report.planeGradePercent))
                if let error = report.gradeErrorPercent {
                    LabeledContent("Grade error", value: String(format: "%+.2f%%", error))
                }
                LabeledContent("Height scatter (rms)", value: String(format: "%.1f mm", report.rmsResidualMillimetres))
                if let median = report.localGradeErrorMedianPercent, let p95 = report.localGradeErrorP95Percent {
                    LabeledContent("Local slope error (median / 95th)", value: String(format: "%.2f%% / %.2f%%", median, p95))
                }
                ForEach(report.buckets, id: \.label) { bucket in
                    LabeledContent("Range \(bucket.label)",
                                   value: String(format: "%.1f mm rms, %d cells", bucket.rmsResidualMillimetres, bucket.cells))
                }
                ShareLink(item: report.json) { Label("Share validation report", systemImage: "square.and.arrow.up") }
            } else {
                Text("Too few cells for a validation report.").font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Validation")
        } footer: {
            Text("Scan a level floor or a board set to a known grade, then compare. Local slope error shows how much slope noise a putt calculation would see.")
        }
    }
}

// MARK: Slope view

struct MapSlopeView: View {
    let record: GreenMapRecord

    var body: some View {
        let grades = MapSlope.grades(cells: record.cells, cellSize: record.cellSize)
        VStack(spacing: 6) {
            Canvas { context, size in
                let polygon = record.edgeVector
                guard let bounds = GreenGeometry.bounds(polygon) else { return }
                let span = bounds.max - bounds.min
                let scale = Double(min((size.width - 16) / CGFloat(max(span.x, 0.1)),
                                       (size.height - 16) / CGFloat(max(span.y, 0.1))))
                let offsetX = (Double(size.width) - Double(span.x) * scale) / 2
                let offsetY = (Double(size.height) - Double(span.y) * scale) / 2
                func point(_ x: Float, _ z: Float) -> CGPoint {
                    CGPoint(x: offsetX + Double(x - bounds.min.x) * scale, y: offsetY + Double(z - bounds.min.y) * scale)
                }
                let cell = CGFloat(Double(record.cellSize) * scale)
                for (index, mapCell) in record.cells.enumerated() {
                    let origin = point(Float(mapCell.ix) * record.cellSize, Float(mapCell.iz) * record.cellSize)
                    let rect = CGRect(x: origin.x, y: origin.y, width: cell + 0.5, height: cell + 0.5)
                    context.fill(Path(rect), with: .color(Self.color(grade: Double(grades[index]))))
                }
                var outline = Path()
                for (index, vertex) in polygon.enumerated() {
                    let p = point(vertex.x, vertex.y)
                    if index == 0 { outline.move(to: p) } else { outline.addLine(to: p) }
                }
                outline.closeSubpath()
                context.stroke(outline, with: .color(.white), lineWidth: 2)
            }
            .frame(height: 320)
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            LinearGradient(colors: [.blue, .green, .yellow, .orange, .red], startPoint: .leading, endPoint: .trailing)
                .frame(height: 8).clipShape(Capsule())
            HStack { Text("0%"); Spacer(); Text("2%"); Spacer(); Text("4%"); Spacer(); Text("6%+") }
                .font(.caption2.monospacedDigit())
            Text(record.headingAligned ? "North is up" : "Orientation is arbitrary (heading unavailable)")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding()
    }

    static func color(grade: Double) -> Color {
        let value = min(1, grade / 0.06)
        return Color(hue: (0.62 - 0.62 * value).clamped(to: 0...0.62), saturation: 0.85, brightness: 0.95)
    }
}

// MARK: Minimap

struct MiniMapCells: View, Equatable {
    let snapshot: MiniMapSnapshot

    static func == (lhs: MiniMapCells, rhs: MiniMapCells) -> Bool { lhs.snapshot == rhs.snapshot }

    var body: some View {
        Canvas { context, size in
            guard let transform = MiniMapTransform(polygon: snapshot.polygon, size: size) else { return }
            let side = CGFloat(snapshot.cellSize) * transform.scale
            var good = Path(), weak = Path(), noisy = Path()
            for c in snapshot.good {
                let p = transform.point(c.x - snapshot.cellSize / 2, c.y - snapshot.cellSize / 2)
                good.addRect(CGRect(x: p.x, y: p.y, width: side + 0.5, height: side + 0.5))
            }
            for c in snapshot.weak {
                let p = transform.point(c.x - snapshot.cellSize / 2, c.y - snapshot.cellSize / 2)
                weak.addRect(CGRect(x: p.x, y: p.y, width: side + 0.5, height: side + 0.5))
            }
            for c in snapshot.noisy {
                let p = transform.point(c.x - snapshot.cellSize / 2, c.y - snapshot.cellSize / 2)
                noisy.addRect(CGRect(x: p.x, y: p.y, width: side + 0.5, height: side + 0.5))
            }
            context.fill(good, with: .color(.green.opacity(0.75)))
            context.fill(weak, with: .color(.orange.opacity(0.8)))
            context.fill(noisy, with: .color(.red.opacity(0.85)))
            var outline = Path()
            for (index, vertex) in snapshot.polygon.enumerated() {
                let p = transform.point(vertex.x, vertex.y)
                if index == 0 { outline.move(to: p) } else { outline.addLine(to: p) }
            }
            if snapshot.closed { outline.closeSubpath() }
            context.stroke(outline, with: .color(.white), lineWidth: 1.5)

            // Zone markers: ring colour shows progress, red means the zone is not tied to the rest of the scan.
            if snapshot.zones.count > 1 {
                for zone in snapshot.zones {
                    let p = transform.point(zone.centre.x, zone.centre.y)
                    let ring: Color
                    switch zone.state {
                    case .notStarted: ring = .white.opacity(0.6)
                    case .inProgress: ring = .orange
                    case .complete: ring = .green
                    }
                    let unlinked = zone.state != .notStarted && !zone.linked
                    let radius: CGFloat = zone.index == snapshot.highlightZone ? 11 : 9
                    let circle = Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
                    context.fill(circle, with: .color(.black.opacity(0.6)))
                    context.stroke(circle, with: .color(unlinked ? .red : ring), lineWidth: zone.index == snapshot.highlightZone ? 3 : 1.5)
                    context.draw(Text("\(zone.index + 1)").font(.caption2.bold()).foregroundColor(.white), at: p)
                }
            }
        }
    }
}

struct MiniMapUser: View {
    let snapshot: MiniMapSnapshot
    let user: SIMD2<Float>?

    var body: some View {
        Canvas { context, size in
            guard let user, let transform = MiniMapTransform(polygon: snapshot.polygon, size: size) else { return }
            let p = transform.point(user.x, user.y)
            context.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(.cyan))
        }
    }
}

struct MiniMapView: View {
    let snapshot: MiniMapSnapshot
    let user: SIMD2<Float>?

    var body: some View {
        ZStack {
            MiniMapCells(snapshot: snapshot).equatable()
            MiniMapUser(snapshot: snapshot, user: user)
        }
        .frame(width: 150, height: 150)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("Minimap of the green showing scanned areas")
    }
}

private struct MiniMapTransform {
    let low: SIMD2<Float>
    let scale: CGFloat
    let offset: CGPoint

    init?(polygon: [SIMD2<Float>], size: CGSize) {
        guard let bounds = GreenGeometry.bounds(polygon) else { return nil }
        let span = bounds.max - bounds.min
        let usable = CGSize(width: size.width - 16, height: size.height - 16)
        scale = min(usable.width / CGFloat(max(span.x, 0.5)), usable.height / CGFloat(max(span.y, 0.5)))
        low = bounds.min
        offset = CGPoint(x: (size.width - CGFloat(span.x) * scale) / 2, y: (size.height - CGFloat(span.y) * scale) / 2)
    }

    func point(_ x: Float, _ z: Float) -> CGPoint {
        CGPoint(x: offset.x + CGFloat(x - low.x) * scale, y: offset.y + CGFloat(z - low.y) * scale)
    }
}

// MARK: Scanning screen

struct MapScanScreen: View {
    @EnvironmentObject private var model: MapModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmDiscard = false

    private func requestCancel() {
        if model.hasUnsavedWork { confirmDiscard = true } else { model.endMapping() }
    }

    var body: some View {
        ZStack {
            MapARViewContainer(model: model)
                .ignoresSafeArea()
                .accessibilityLabel("Camera view of the green")
            if model.phase == .edge {
                Image(systemName: "plus")
                    .font(.title.weight(.light))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            VStack(spacing: 12) {
                header
                Spacer()
                HStack(alignment: .bottom) {
                    if !model.minimap.polygon.isEmpty {
                        MiniMapView(snapshot: model.minimap, user: model.userPosition)
                    }
                    Spacer()
                }
                controls
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if model.phase == .review { reviewOverlay }
        }
        .onChange(of: scenePhase) { _, newPhase in model.setSessionActive(newPhase == .active) }
        .confirmationDialog("Discard this scan?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard scan", role: .destructive) { model.endMapping() }
            Button("Keep scanning", role: .cancel) {}
        } message: {
            Text("The scan so far will be deleted. Progress is otherwise saved automatically.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.phase == .edge ? "scope" : "wave.3.right").foregroundStyle(.mint)
            VStack(alignment: .leading, spacing: 2) {
                Text(instruction).font(.subheadline.weight(.semibold))
                Text("\(model.courseName) · Hole \(model.holeNumber) · \(model.trackingText)")
                    .font(.caption).foregroundStyle(.secondary)
                if model.phase == .scanning, let advice = model.coachMessage {
                    Label(advice, systemImage: "figure.walk.motion")
                        .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                }
            }
            Spacer()
            if model.phase == .scanning {
                Text(model.coverage, format: .percent.precision(.fractionLength(0)))
                    .font(.headline).monospacedDigit()
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private var instruction: String {
        switch model.phase {
        case .edge where model.awaitingRelocalization: return "Walk back to where you were marking the edge and point at the ground."
        case .scanning where model.awaitingRelocalization: return "Walk back to where you were scanning and point at the ground until tracking resumes."
        case .edge: return "Walk the edge of the green and mark where the fringe begins."
        case .scanning: return model.zoneGuidance
        case .review: return "Review the scan."
        }
    }

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 10) {
            if model.awaitingRelocalization {
                Text("Waiting for the camera to recognise the spot. If it does not, you can keep the saved scan for later or save what was captured.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Leave for later") { model.leaveKeepingDraft() }.buttonStyle(.bordered)
                    Spacer()
                    if model.draft?.hasScanData == true {
                        Button("Save what was captured") { model.abandonRelocalizationAndSave() }
                            .buttonStyle(.borderedProminent).tint(.mint)
                    }
                }
            } else {
            switch model.phase {
            case .edge:
                Toggle("Auto-drop a point every 2 m", isOn: $model.autoEdge)
                Text("\(model.edgePointCount) edge points · aim the + at the edge, then tap anywhere or press Add point")
                    .font(.caption).foregroundStyle(.secondary)
                if let problem = model.edgeProblem {
                    Text(problem).font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button("Cancel", role: .destructive) { requestCancel() }.buttonStyle(.bordered)
                    Button("Undo") { model.undoEdgePoint() }
                        .buttonStyle(.bordered).disabled(model.edgePointCount == 0)
                    Spacer()
                    Button("Add point") { model.addPointAtCentre() }.buttonStyle(.bordered)
                    Button("Close shape") { model.closeShape() }
                        .buttonStyle(.borderedProminent).tint(.mint).disabled(model.edgePointCount < 4)
                }
            case .scanning:
                ProgressView(value: model.coverage).tint(.mint).accessibilityLabel("Scan coverage")
                Text("Progress is saved automatically.").font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Label("Scanned", systemImage: "square.fill").foregroundStyle(.green)
                    Label("Closer", systemImage: "square.fill").foregroundStyle(.orange)
                    Label("Noisy", systemImage: "square.fill").foregroundStyle(.red)
                    Spacer()
                    Text("Quality \(model.quality.formatted(.percent.precision(.fractionLength(0))))")
                        .monospacedDigit()
                }
                .font(.caption)
                if let drift = model.driftMillimetres, drift > 8 {
                    let fixed = model.residualMillimetres.map { String(format: ", corrected to %.0f mm", $0) } ?? ""
                    Label(String(format: "Height drift about %.0f mm between passes", drift) + fixed + ".",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle((model.residualMillimetres ?? drift) > 8 ? Color.orange : Color.secondary)
                }
                if model.trackingLossCount > 0 {
                    Label("Tracking lost \(model.trackingLossCount) time(s). Revisit those areas.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button("Cancel", role: .destructive) { requestCancel() }.buttonStyle(.bordered)
                    Spacer()
                    Button("Finish") { model.finishScanning() }
                        .buttonStyle(.borderedProminent).tint(.mint)
                }
            case .review:
                EmptyView()
            }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .opacity(model.phase == .review ? 0 : 1)
    }

    private var reviewOverlay: some View {
        VStack(spacing: 12) {
            if let record = model.reviewRecord {
                Text("\(record.courseName) · Hole \(record.holeNumber)").font(.headline)
                ScrollView { MapSlopeView(record: record) }
                HStack {
                    stat("Coverage", record.coverage)
                    stat("Quality", record.qualityScore)
                }
                if let unlinked = record.unlinkedZones, unlinked > 0 {
                    Label("\(unlinked) zone(s) are not tied to the rest of the scan, so their heights are uncorrected.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                if record.isPartial {
                    Label("Partial scan: under 85% of the green is covered.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button("Discard", role: .destructive) { model.endMapping() }.buttonStyle(.bordered)
                    Button("Keep scanning") { model.resumeScanning() }.buttonStyle(.bordered)
                    Spacer()
                    Button("Save green") { model.saveReviewedGreen() }
                        .buttonStyle(.borderedProminent).tint(.mint)
                }
            } else {
                ProgressView("Building map…")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .ignoresSafeArea()
    }

    private func stat(_ title: String, _ value: Double) -> some View {
        VStack {
            Text(value.formatted(.percent.precision(.fractionLength(0)))).font(.title3.bold())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct MapARViewContainer: UIViewRepresentable {
    let model: MapModel

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.didTap(_:))))
        model.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    @MainActor final class Coordinator: NSObject {
        let model: MapModel
        init(model: MapModel) { self.model = model }
        @objc func didTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            model.handleTap(recognizer.location(in: view))
        }
    }
}
