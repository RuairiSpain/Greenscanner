import Foundation

enum UnitSystem: String, CaseIterable, Identifiable, Sendable {
    case metric
    case imperial

    var id: String { rawValue }
    var label: String { self == .metric ? "Metric (m, cm)" : "Imperial (ft, in)" }

    /// Putt distance, e.g. "3.2 m" or "10.5 ft".
    func distance(_ metres: Double) -> String {
        switch self {
        case .metric: return String(format: "%.1f m", metres)
        case .imperial: return String(format: "%.1f ft", metresToFeet(metres))
        }
    }

    /// Short lengths such as aim offsets, e.g. "12 cm" or "5 in".
    func shortLength(_ metres: Double) -> String {
        switch self {
        case .metric: return String(format: "%.0f cm", metres * 100)
        case .imperial: return String(format: "%.0f in", metres * 39.370_078_74)
        }
    }

    func speed(_ metresPerSecond: Double) -> String {
        switch self {
        case .metric: return String(format: "%.2f m/s", metresPerSecond)
        case .imperial: return String(format: "%.2f ft/s", metresToFeet(metresPerSecond))
        }
    }
}

enum CSVExporter {
    /// One row per surface cell, in the ball-to-cup frame: +x is the golfer's right, +y is toward the cup.
    static func surfaceCSV(for record: ScanRecord) -> String {
        let size = Double(record.surface.cellSize)
        var lines = ["x_m,y_m,height_m,variance_m2,observations"]
        lines.reserveCapacity(record.surface.cells.count + 1)
        for cell in record.surface.cells {
            let x = (Double(cell.x) + 0.5) * size
            let y = (Double(cell.y) + 0.5) * size
            lines.append(String(format: "%.4f,%.4f,%.5f,%.8f,%d", x, y, Double(cell.height), Double(cell.variance), cell.observations))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
