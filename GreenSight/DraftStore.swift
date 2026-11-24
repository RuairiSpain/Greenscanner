import Foundation
import simd

/// Small summary of an unfinished scan, shown without loading the full data.
struct MapDraftHeader: Codable, Sendable {
    var courseName: String
    var holeNumber: Int
    /// "edge" or "scanning".
    var phase: String
    var savedAt: Date
    var coverage: Double
    var edgePointCount: Int
    var hasScanData: Bool
    var hasWorldMap: Bool
}

struct MapDraftPayload: Codable, Sendable {
    var edgeWorld: [SIMD3<Float>]
    var origin: SIMD3<Float>
    var headingAligned: Bool
    var originLatitude: Double?
    var originLongitude: Double?
    var trackingLossCount: Int
    var depthSource: String
    var accumulator: GreenMapAccumulator.Snapshot?
}

/// Persists one in-progress mapping session so a crash, phone call or low battery does not lose it.
/// The header is written last, so a partly written draft is never offered for recovery.
final class DraftStore: @unchecked Sendable {
    private let directory: URL
    private var headerURL: URL { directory.appendingPathComponent("draft-header.json") }
    private var payloadURL: URL { directory.appendingPathComponent("draft-payload.plist") }
    private var worldMapURL: URL { directory.appendingPathComponent("draft.worldmap") }

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = base.appendingPathComponent("GreenSight/Draft", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    /// Writes the draft. A nil `worldMapData` keeps any world map already saved for this draft.
    @discardableResult
    func save(header: MapDraftHeader, payload: MapDraftPayload, worldMapData: Data?) -> MapDraftHeader? {
        var header = header
        do {
            if let worldMapData { try worldMapData.write(to: worldMapURL, options: .atomic) }
            let plist = PropertyListEncoder()
            plist.outputFormat = .binary
            try plist.encode(payload).write(to: payloadURL, options: .atomic)
            header.hasWorldMap = FileManager.default.fileExists(atPath: worldMapURL.path)
            let json = JSONEncoder()
            json.dateEncodingStrategy = .iso8601
            try json.encode(header).write(to: headerURL, options: .atomic)
            return header
        } catch {
            return nil
        }
    }

    func loadHeader() -> MapDraftHeader? {
        guard let data = try? Data(contentsOf: headerURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MapDraftHeader.self, from: data)
    }

    func loadPayload() -> MapDraftPayload? {
        guard let data = try? Data(contentsOf: payloadURL) else { return nil }
        return try? PropertyListDecoder().decode(MapDraftPayload.self, from: data)
    }

    func loadWorldMapData() -> Data? {
        try? Data(contentsOf: worldMapURL)
    }

    func delete() {
        for url in [headerURL, payloadURL, worldMapURL] { try? FileManager.default.removeItem(at: url) }
    }
}
