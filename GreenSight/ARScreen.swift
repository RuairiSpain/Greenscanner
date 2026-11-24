import SwiftUI
import RealityKit

struct ARScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showHeatMapSheet = false

    var body: some View {
        ZStack {
            ARViewContainer(model: model)
                .ignoresSafeArea(edges: .top)
                .accessibilityLabel("Camera view of the green")
            LinearGradient(colors: [.black.opacity(0.5), .clear, .black.opacity(0.7)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
                .ignoresSafeArea(edges: .top)

            VStack(spacing: 12) {
                statusHeader
                Spacer()
                if model.showDiagnostics { diagnostics }
                controlCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .sheet(isPresented: $showHeatMapSheet) {
            NavigationStack {
                HeatMapView(snapshot: model.surface)
                    .navigationTitle("Slope map")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showHeatMapSheet = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
        .onChange(of: scenePhase) { _, newPhase in
            model.setSessionActive(newPhase == .active)
        }
        .onAppear { model.setScreenVisible(true) }
        .onDisappear { model.setScreenVisible(false) }
    }

    private var statusHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.phase.instruction)
                    .font(.subheadline.weight(.semibold))
                Text(model.trackingText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.phase == .scanning {
                Text(model.coverage, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .font(.headline)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var controlCard: some View {
        VStack(spacing: 12) {
            switch model.phase {
            case .idle:
                primaryButton("Start green scan", icon: "camera.viewfinder") { model.startNewScan() }
                Button("Run demo without LiDAR") { model.runDemo() }
                    .buttonStyle(.bordered)
            case .markBall, .markCup:
                HStack {
                    Label(model.autoDetection ? "Auto-detection on" : "Tap detection", systemImage: "scope")
                        .font(.caption)
                    Spacer()
                    if model.phase == .markCup {
                        Button("Redo ball") { model.undoLandmark() }
                    }
                    Button("Restart") { model.startNewScan() }
                }
            case .scanning:
                ProgressView(value: model.coverage)
                    .tint(.mint)
                    .accessibilityLabel("Scan coverage")
                if model.trackingLostDuringScan {
                    Label("Tracking was lost during this scan. Restart if the line looks off.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                HStack {
                    Button("Restart", role: .destructive) { model.startNewScan() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button {
                        showHeatMapSheet = true
                    } label: {
                        Label("Map", systemImage: "map")
                    }
                    .buttonStyle(.bordered)
                    primaryButton("Calculate", icon: "function") { model.finishScan() }
                        .disabled(model.surface.cells.count < 30)
                }
            case .processing:
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Optimising launch line and speed…")
                }
            case .result:
                resultSummary
                HStack {
                    Button { showHeatMapSheet = true } label: { Label("Slope map", systemImage: "map.fill") }
                        .buttonStyle(.bordered)
                    if let url = model.exportURL {
                        Menu {
                            ShareLink(item: url) { Label("JSON (full read)", systemImage: "curlybraces") }
                            if let csv = model.csvURL {
                                ShareLink(item: csv) { Label("CSV (surface cells)", systemImage: "tablecells") }
                            }
                        } label: { Label("Export", systemImage: "square.and.arrow.up") }
                            .buttonStyle(.bordered)
                    }
                    Spacer()
                    Button("New scan") { model.startNewScan() }
                        .buttonStyle(.borderedProminent)
                        .tint(.mint)
                }
            case .unsupported:
                primaryButton("Run interactive demo", icon: "play.fill") { model.runDemo() }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private var resultSummary: some View {
        if let result = model.solution {
            HStack(spacing: 18) {
                metric(title: "Aim", value: aimText(result))
                metric(title: "Start speed", value: model.units.speed(result.launchSpeedMetresPerSecond))
                metric(title: "Confidence", value: result.confidence.formatted(.percent.precision(.fractionLength(0))))
                if let chance = result.holeProbability {
                    metric(title: "Holes out", value: chance.formatted(.percent.precision(.fractionLength(0))))
                }
            }
            if !result.holed {
                Label("Best measured line misses the cup by \(model.units.shortLength(result.closestDistanceMetres)). Rescan for more coverage.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var diagnostics: some View {
        HStack {
            Text("Cells \(model.surface.cells.count)")
            Spacer()
            Text("Grid \(Int(model.surface.cellSize * 1000)) mm")
            Spacer()
            Text("Stimp \(model.stimpFeet, specifier: "%.1f")")
        }
        .font(.caption.monospacedDigit())
        .padding(8)
        .background(.black.opacity(0.55), in: Capsule())
    }

    private func metric(title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline).minimumScaleFactor(0.7)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func aimText(_ result: PuttSolution) -> String {
        let metres = abs(result.aimOffsetCentimetres) / 100
        if metres < 0.01 { return "Straight" }
        return "\(model.units.shortLength(metres)) \(result.aimOffsetCentimetres > 0 ? "right" : "left")"
    }

    private func primaryButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).fontWeight(.semibold) }
            .buttonStyle(.borderedProminent)
            .tint(.mint)
    }

    private var statusIcon: String {
        switch model.phase {
        case .result: return model.solution?.holed == true ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
        case .unsupported: return "iphone.slash"
        case .scanning: return "wave.3.right"
        default: return "scope"
        }
    }

    private var statusColor: Color {
        switch model.phase {
        case .result: return model.solution?.holed == true ? .green : .orange
        case .unsupported: return .orange
        default: return .mint
        }
    }
}

struct ARViewContainer: UIViewRepresentable {
    let model: AppModel

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.didTap(_:))))
        model.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    @MainActor final class Coordinator: NSObject {
        let model: AppModel
        init(model: AppModel) { self.model = model }
        @objc func didTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            model.handleTap(recognizer.location(in: view))
        }
    }
}
