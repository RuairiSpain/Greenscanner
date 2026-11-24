import Foundation
import CoreLocation

/// Stores one JSON file per mapped green so saving a new green never rewrites the others.
final class GreenMapStore: @unchecked Sendable {
    enum StoreError: LocalizedError {
        case unreadable, unsupportedFormat, invalid
        var errorDescription: String? {
            switch self {
            case .unreadable: return "The file could not be read as a GreenSight green."
            case .unsupportedFormat: return "This green was saved by a newer version of GreenSight."
            case .invalid: return "The green file is incomplete or damaged."
            }
        }
    }

    private let directory: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("GreenSight/Greens", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func loadAll() -> [GreenMapRecord] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(GreenMapRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func save(_ record: GreenMapRecord) {
        guard let data = try? encoder.encode(record) else { return }
        try? data.write(to: fileURL(record.id), options: .atomic)
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(id))
    }

    func export(_ record: GreenMapRecord) throws -> URL {
        let safeCourse = record.courseName.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
            .map(String.init).joined()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeCourse)-hole-\(record.holeNumber).greensight.json")
        try encoder.encode(record).write(to: url, options: .atomic)
        return url
    }

    func importRecord(from url: URL) throws -> GreenMapRecord {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let record = try? decoder.decode(GreenMapRecord.self, from: data) else { throw StoreError.unreadable }
        guard record.format <= GreenMapRecord.currentFormat else { throw StoreError.unsupportedFormat }
        guard record.cellSize > 0, record.edge.count >= 3, !record.cells.isEmpty,
              record.cells.count <= 500_000, (1...36).contains(record.holeNumber) else { throw StoreError.invalid }
        return record
    }
}

/// One-shot location and heading availability. Used to stamp a scan's origin and to align the AR world to north.
final class LocationProvider: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private let manager = CLLocationManager()
    private(set) var latest: CLLocation?
    var onFirstFix: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func start() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.startUpdatingLocation()
    }

    func stop() { manager.stopUpdatingLocation() }

    var canAlignToHeading: Bool {
        let status = manager.authorizationStatus
        return (status == .authorizedWhenInUse || status == .authorizedAlways) && CLLocationManager.headingAvailable()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let isFirst = latest == nil
        latest = locations.last
        if isFirst { onFirstFix?() }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }
}
