import SwiftUI
import simd

struct HeatMapView: View {
    let snapshot: HeightMapSnapshot
    @State private var showContours = true

    var body: some View {
        VStack(spacing: 12) {
            if snapshot.cells.isEmpty {
                ContentUnavailableView("No surface yet", systemImage: "map", description: Text("Scan more of the putting corridor."))
            } else {
                let surface = GreenSurface(snapshot: snapshot)
                Canvas { context, size in
                    let width = max(1, snapshot.maxX - snapshot.minX + 1)
                    let height = max(1, snapshot.maxY - snapshot.minY + 1)
                    let cellWidth = size.width / CGFloat(width)
                    let cellHeight = size.height / CGFloat(height)
                    for cell in snapshot.cells {
                        let grade = simd_length(surface.gradient(at: cell))
                        let color = slopeColor(grade)
                        let rect = CGRect(x: CGFloat(cell.x - snapshot.minX) * cellWidth,
                                          y: size.height - CGFloat(cell.y - snapshot.minY + 1) * cellHeight,
                                          width: cellWidth + 0.5, height: cellHeight + 0.5)
                        context.fill(Path(rect), with: .color(color))
                        if showContours {
                            let interval: Float = 0.01
                            let band = Int(floor(cell.height / interval))
                            if band.isMultiple(of: 2) {
                                context.stroke(Path(rect), with: .color(.white.opacity(0.10)), lineWidth: 0.35)
                            }
                        }
                    }
                }
                .aspectRatio(0.65, contentMode: .fit)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .top) { Label("CUP", systemImage: "flag.fill").font(.caption).padding(6) }
                .overlay(alignment: .bottom) { Label("BALL", systemImage: "circle.fill").font(.caption).padding(6) }
                legend
            }
            Toggle("Elevation contour shading", isOn: $showContours)
        }
        .padding()
    }

    private var legend: some View {
        VStack(spacing: 4) {
            LinearGradient(colors: [.blue, .green, .yellow, .orange, .red], startPoint: .leading, endPoint: .trailing)
                .frame(height: 10)
                .clipShape(Capsule())
            HStack { Text("0%"); Spacer(); Text("2%"); Spacer(); Text("4%"); Spacer(); Text("6%+") }
                .font(.caption2.monospacedDigit())
        }
    }

    private func slopeColor(_ grade: Double) -> Color {
        let value = min(1, grade / 0.06)
        let hue = (0.62 - 0.62 * value).clamped(to: 0...0.62)
        return Color(hue: hue, saturation: 0.85, brightness: 0.95)
    }
}
