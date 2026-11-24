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

    private var groupedCourses: [CourseGroup] {
        Dictionary(grouping: model.records, by: \.courseName)
            .map { CourseGroup(course: $0.key, records: $0.value.sorted { $0.holeNumber < $1.holeNumber }) }
            .sorted { $0.course.localizedCaseInsensitiveCompare($1.course) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
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
            .alert("Import failed", isPresented: Binding(get: { model.importError != nil },
                                                          set: { if !$0 { model.importError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(model.importError ?? "") }
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
                    LabeledContent("Height drift", value: String(format: "%.0f mm", drift))
                }
                LabeledContent("Tracking losses", value: "\(record.trackingLossCount)")
                LabeledContent("Cells", value: "\(record.cells.count)")
                LabeledContent("North-aligned", value: record.headingAligned ? "Yes" : "No")
            }
            if let url = exportURL {
                Section { ShareLink(item: url) { Label("Export green file", systemImage: "square.and.arrow.up") } }
            }
        }
        .navigationTitle("\(record.courseName) \(record.holeNumber)")
        .task { exportURL = await model.prepareExport(record) }
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
            var good = Path(), weak = Path()
            for c in snapshot.good {
                let p = transform.point(c.x - snapshot.cellSize / 2, c.y - snapshot.cellSize / 2)
                good.addRect(CGRect(x: p.x, y: p.y, width: side + 0.5, height: side + 0.5))
            }
            for c in snapshot.weak {
                let p = transform.point(c.x - snapshot.cellSize / 2, c.y - snapshot.cellSize / 2)
                weak.addRect(CGRect(x: p.x, y: p.y, width: side + 0.5, height: side + 0.5))
            }
            context.fill(good, with: .color(.green.opacity(0.75)))
            context.fill(weak, with: .color(.orange.opacity(0.8)))
            var outline = Path()
            for (index, vertex) in snapshot.polygon.enumerated() {
                let p = transform.point(vertex.x, vertex.y)
                if index == 0 { outline.move(to: p) } else { outline.addLine(to: p) }
            }
            if snapshot.closed { outline.closeSubpath() }
            context.stroke(outline, with: .color(.white), lineWidth: 1.5)
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
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.phase == .edge ? "scope" : "wave.3.right").foregroundStyle(.mint)
            VStack(alignment: .leading, spacing: 2) {
                Text(instruction).font(.subheadline.weight(.semibold))
                Text("\(model.courseName) · Hole \(model.holeNumber) · \(model.trackingText)")
                    .font(.caption).foregroundStyle(.secondary)
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
        case .edge: return "Walk the edge of the green and mark where the fringe begins."
        case .scanning: return "Walk the inside. Cover the grey areas on the map."
        case .review: return "Review the scan."
        }
    }

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 10) {
            switch model.phase {
            case .edge:
                Toggle("Auto-drop a point every 2 m", isOn: $model.autoEdge)
                Text("\(model.edgePointCount) edge points · aim the + at the edge, then tap anywhere or press Add point")
                    .font(.caption).foregroundStyle(.secondary)
                if let problem = model.edgeProblem {
                    Text(problem).font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button("Cancel", role: .destructive) { model.endMapping() }.buttonStyle(.bordered)
                    Button("Undo") { model.undoEdgePoint() }
                        .buttonStyle(.bordered).disabled(model.edgePointCount == 0)
                    Spacer()
                    Button("Add point") { model.addPointAtCentre() }.buttonStyle(.bordered)
                    Button("Close shape") { model.closeShape() }
                        .buttonStyle(.borderedProminent).tint(.mint).disabled(model.edgePointCount < 4)
                }
            case .scanning:
                ProgressView(value: model.coverage).tint(.mint).accessibilityLabel("Scan coverage")
                HStack {
                    Label("Scanned", systemImage: "square.fill").foregroundStyle(.green)
                    Label("Scan closer", systemImage: "square.fill").foregroundStyle(.orange)
                    Spacer()
                    Text("Quality \(model.quality.formatted(.percent.precision(.fractionLength(0))))")
                        .monospacedDigit()
                }
                .font(.caption)
                if let drift = model.driftMillimetres, drift > 8 {
                    Label(String(format: "Height drift about %.0f mm. Close loops and avoid long straight walks.", drift),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                if model.trackingLossCount > 0 {
                    Label("Tracking lost \(model.trackingLossCount) time(s). Revisit those areas.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button("Cancel", role: .destructive) { model.endMapping() }.buttonStyle(.bordered)
                    Spacer()
                    Button("Finish") { model.finishScanning() }
                        .buttonStyle(.borderedProminent).tint(.mint)
                }
            case .review:
                EmptyView()
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
