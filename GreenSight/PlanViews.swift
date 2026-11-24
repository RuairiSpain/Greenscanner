import SwiftUI
import simd

// MARK: Choose a green

struct PlanHomeView: View {
    @EnvironmentObject private var mapModel: MapModel

    private struct CourseGroup: Identifiable {
        let course: String
        let records: [GreenMapRecord]
        var id: String { course }
    }

    private var groups: [CourseGroup] {
        Dictionary(grouping: mapModel.records, by: \.courseName)
            .map { CourseGroup(course: $0.key, records: $0.value.sorted { ($0.holeNumber, $1.createdAt) < ($1.holeNumber, $0.createdAt) }) }
            .sorted { $0.course.localizedCaseInsensitiveCompare($1.course) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            Group {
                if mapModel.records.isEmpty {
                    ContentUnavailableView("No greens yet", systemImage: "map",
                                           description: Text("Map a green in the Map tab, or import a green file there. Saved greens can then be used here to plan putts without scanning."))
                } else {
                    List {
                        if let nearby = mapModel.nearbyCourseSuggestion,
                           let group = groups.first(where: { $0.course == nearby }) {
                            Section("Near you") { rows(group.records) }
                        }
                        ForEach(groups) { group in
                            Section(group.course) { rows(group.records) }
                        }
                    }
                }
            }
            .navigationTitle("Plan a putt")
            .onAppear { mapModel.location.start() }
        }
    }

    @ViewBuilder
    private func rows(_ records: [GreenMapRecord]) -> some View {
        ForEach(records) { record in
            NavigationLink {
                PuttPlannerView(record: record)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(record.courseName) · Hole \(record.holeNumber)").font(.headline)
                        Text(record.createdAt, format: .dateTime.day().month().year())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(record.coverage, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                        Text(record.isPartial ? "Partial" : "Complete").font(.caption)
                            .foregroundStyle(record.isPartial ? .orange : .green)
                    }
                }
            }
        }
    }
}

// MARK: Planner

/// Top-down map-to-screen mapping shared by drawing and tap handling.
struct PlanLayout {
    let bounds: (min: SIMD2<Float>, max: SIMD2<Float>)
    let scale: CGFloat
    let offset: CGPoint

    init?(polygon: [SIMD2<Float>], size: CGSize, padding: CGFloat = 14) {
        guard let b = GreenGeometry.bounds(polygon), size.width > 0, size.height > 0 else { return nil }
        let span = b.max - b.min
        bounds = b
        scale = min((size.width - 2 * padding) / CGFloat(max(span.x, 0.5)), (size.height - 2 * padding) / CGFloat(max(span.y, 0.5)))
        offset = CGPoint(x: (size.width - CGFloat(span.x) * scale) / 2, y: (size.height - CGFloat(span.y) * scale) / 2)
    }

    func point(_ p: SIMD2<Float>) -> CGPoint {
        CGPoint(x: offset.x + CGFloat(p.x - bounds.min.x) * scale, y: offset.y + CGFloat(p.y - bounds.min.y) * scale)
    }

    func map(_ point: CGPoint) -> SIMD2<Float> {
        SIMD2<Float>(Float((point.x - offset.x) / scale) + bounds.min.x, Float((point.y - offset.y) / scale) + bounds.min.y)
    }
}

struct PuttPlannerView: View {
    @EnvironmentObject private var model: AppModel
    let record: GreenMapRecord

    private enum Placing: String, CaseIterable, Identifiable {
        case ball, cup
        var id: String { rawValue }
        var label: String { self == .ball ? "Place ball" : "Place cup" }
    }

    @State private var placing: Placing = .ball
    @State private var ball: SIMD2<Float>?
    @State private var cup: SIMD2<Float>?
    @State private var stimp = 10.0
    @State private var planned: PlannedPutt?
    @State private var errorText: String?
    @State private var computing = false
    @State private var requestID = UUID()
    @State private var layer: SlopeLayer = .slope
    @State private var showArrows = true
    @State private var photo: UIImage?
    @State private var summary: GreenSummary?
    @State private var grades: [Float] = []
    @State private var arrows: [(origin: SIMD2<Float>, uphill: SIMD2<Float>)] = []
    @State private var prepared = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                mapView
                controls
                if let summary { overview(summary) }
                if computing { ProgressView("Planning the putt…") }
                if let errorText { Label(errorText, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
                if let planned { resultCard(planned) }
            }
            .padding()
        }
        .navigationTitle("\(record.courseName) \(record.holeNumber)")
        .navigationBarTitleDisplayMode(.inline)
        .task { prepare() }
    }

    // MARK: Map

    private var mapView: some View {
        GeometryReader { proxy in
            Canvas { context, size in draw(context, size) }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                    guard let layout = PlanLayout(polygon: record.edgeVector, size: proxy.size) else { return }
                    place(layout.map(value.location))
                })
        }
        .frame(height: 380)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("Map of the green. Tap to place the ball or the cup.")
    }

    private func draw(_ context: GraphicsContext, _ size: CGSize) {
        guard let layout = PlanLayout(polygon: record.edgeVector, size: size) else { return }
        var context = context
        let side = CGFloat(record.cellSize) * layout.scale

        if layer != .slope, let photo, let image = record.image {
            let corner = layout.point(SIMD2<Float>(image.minX, image.minZ))
            context.draw(Image(uiImage: photo), in: CGRect(x: corner.x, y: corner.y,
                                                           width: CGFloat(image.widthMetres) * layout.scale,
                                                           height: CGFloat(image.heightMetres) * layout.scale))
        }
        if layer != .photo || photo == nil, grades.count == record.cells.count {
            let opacity = (layer == .both && photo != nil) ? 0.45 : 1.0
            for (index, cell) in record.cells.enumerated() {
                let p = layout.point(SIMD2<Float>(Float(cell.ix) * record.cellSize, Float(cell.iz) * record.cellSize))
                context.fill(Path(CGRect(x: p.x, y: p.y, width: side + 0.5, height: side + 0.5)),
                             with: .color(MapSlopeView.color(grade: Double(grades[index])).opacity(opacity)))
            }
        }
        if showArrows {
            for arrow in arrows {
                let magnitude = simd_length(arrow.uphill)
                guard magnitude > 0.004 else { continue }
                let down = -arrow.uphill / magnitude
                let centre = layout.point(arrow.origin)
                let length = CGFloat(min(1, magnitude / 0.04)) * 14 + 6
                let direction = CGPoint(x: CGFloat(down.x), y: CGFloat(down.y))
                let tip = CGPoint(x: centre.x + direction.x * length / 2, y: centre.y + direction.y * length / 2)
                let tail = CGPoint(x: centre.x - direction.x * length / 2, y: centre.y - direction.y * length / 2)
                var path = Path()
                path.move(to: tail)
                path.addLine(to: tip)
                for sign: CGFloat in [-1, 1] {
                    let angle = atan2(direction.y, direction.x) + .pi + sign * 0.5
                    path.move(to: tip)
                    path.addLine(to: CGPoint(x: tip.x + cos(angle) * 4, y: tip.y + sin(angle) * 4))
                }
                context.stroke(path, with: .color(.black.opacity(0.55)), lineWidth: 1.2)
            }
        }

        var outline = Path()
        for (index, vertex) in record.edgeVector.enumerated() {
            let p = layout.point(vertex)
            if index == 0 { outline.move(to: p) } else { outline.addLine(to: p) }
        }
        outline.closeSubpath()
        context.stroke(outline, with: .color(.white), lineWidth: 2)

        if let planned {
            var aim = Path()
            aim.move(to: layout.point(planned.ball))
            aim.addLine(to: layout.point(planned.aimPoint))
            context.stroke(aim, with: .color(.yellow), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            let aimPoint = layout.point(planned.aimPoint)
            context.fill(Path(ellipseIn: CGRect(x: aimPoint.x - 4, y: aimPoint.y - 4, width: 8, height: 8)), with: .color(.yellow))

            var route = Path()
            for (index, vertex) in planned.path.enumerated() {
                let p = layout.point(vertex)
                if index == 0 { route.move(to: p) } else { route.addLine(to: p) }
            }
            context.stroke(route, with: .color(planned.solution.holed ? .white : .orange), lineWidth: 3)
        }
        if let cup {
            let p = layout.point(cup)
            context.fill(Path(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)), with: .color(.black))
            context.stroke(Path(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)), with: .color(.white), lineWidth: 2)
        }
        if let ball {
            let p = layout.point(ball)
            context.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(.white))
            context.stroke(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(.black), lineWidth: 1)
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 10) {
            Picker("Placing", selection: $placing) {
                ForEach(Placing.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                Text("Stimp")
                Slider(value: $stimp, in: 7...14, step: 0.5)
                Text(stimp, format: .number.precision(.fractionLength(1))).monospacedDigit().frame(width: 36)
            }
            .onChange(of: stimp) { _, _ in recompute() }
            HStack {
                Toggle("Slope arrows", isOn: $showArrows)
                if record.image != nil {
                    Picker("Layer", selection: $layer) {
                        ForEach(SlopeLayer.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .font(.caption)
            Text("Tap the map to place the ball, then switch to the cup and tap where the hole is today. Arrows point downhill; colour shows steepness.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func overview(_ summary: GreenSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Green overview").font(.headline)
            Text(summary.fallDescription).font(.subheadline)
            Text(String(format: "Average slope %.1f%%, steepest 5%% above %.1f%%, about %@ of height change, %.0f m².",
                        summary.meanGradePercent, summary.steepGradePercent,
                        model.units.shortLength(summary.elevationRangeCentimetres / 100), summary.areaSquareMetres))
                .font(.caption).foregroundStyle(.secondary)
            if let pin = record.pinDate {
                Text("Cup marked \(pin.formatted(date: .abbreviated, time: .omitted)).").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func resultCard(_ putt: PlannedPutt) -> some View {
        let solution = putt.solution
        let offset = abs(solution.aimOffsetCentimetres) / 100
        return VStack(alignment: .leading, spacing: 8) {
            Text("Your putt").font(.headline)
            HStack(spacing: 18) {
                metric("Distance", model.units.distance(putt.distanceMetres))
                metric("Start speed", model.units.speed(solution.launchSpeedMetresPerSecond))
                metric("Holes out", (solution.holeProbability ?? 0).formatted(.percent.precision(.fractionLength(0))))
            }
            Text(offset < 0.01 ? "Aim straight at the cup."
                 : "Aim \(model.units.shortLength(offset)) \(solution.aimOffsetCentimetres > 0 ? "right" : "left") of the cup.")
                .font(.subheadline.weight(.semibold))
            if putt.breakCentimetres >= 2 {
                Text("The ball peaks \(model.units.shortLength(putt.breakCentimetres / 100)) off the straight line and curves back.")
                    .font(.caption)
            }
            if let rise = putt.elevationChangeCentimetres, abs(rise) >= 1 {
                Text("\(rise > 0 ? "Uphill" : "Downhill") by \(model.units.shortLength(abs(rise) / 100)).").font(.caption)
            }
            Text(String(format: "%.0f%% of the line has scan data.", putt.corridorCoverage * 100))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(putt.notes, id: \.self) { note in
                Label(note, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
            Text("Planned from a saved scan, not measured on the day. Check the real green, and never walk on another player's line.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline).minimumScaleFactor(0.7)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Actions

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        stimp = record.metadata?.conditions.stimpFeet ?? model.stimpFeet
        cup = record.cup?.vector
        if cup != nil { placing = .ball }
        let record = self.record
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> ([Float], [(origin: SIMD2<Float>, uphill: SIMD2<Float>)], GreenSummary?) in
                let grades = MapSlope.grades(cells: record.cells, cellSize: record.cellSize)
                let vectors = MapSlope.gradientVectors(cells: record.cells, cellSize: record.cellSize)
                var arrows: [(origin: SIMD2<Float>, uphill: SIMD2<Float>)] = []
                for (index, cell) in record.cells.enumerated() where cell.ix % 5 == 0 && cell.iz % 5 == 0 {
                    guard let vector = vectors[index] else { continue }
                    arrows.append((SIMD2<Float>((Float(cell.ix) + 0.5) * record.cellSize, (Float(cell.iz) + 0.5) * record.cellSize), vector))
                }
                return (grades, arrows, GreenSummary.make(from: record))
            }.value
            grades = result.0
            arrows = result.1
            summary = result.2
            photo = record.image?.uiImage
        }
    }

    private func place(_ point: SIMD2<Float>) {
        switch placing {
        case .ball:
            ball = point
            if cup == nil { placing = .cup }
        case .cup:
            cup = point
        }
        recompute()
    }

    private func recompute() {
        guard let ball, let cup else { planned = nil; return }
        computing = true
        errorText = nil
        let id = UUID()
        requestID = id
        let record = self.record, stimp = self.stimp
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<PlannedPutt, PuttPlanError> in
                do { return .success(try PuttPlanner.plan(record: record, ball: ball, cup: cup, stimpFeet: stimp)) }
                catch let error as PuttPlanError { return .failure(error) }
                catch { return .failure(.sparseData) }
            }.value
            guard requestID == id else { return }
            computing = false
            switch outcome {
            case .success(let putt):
                planned = putt
                errorText = nil
            case .failure(let error):
                planned = nil
                errorText = error.errorDescription
            }
        }
    }
}
