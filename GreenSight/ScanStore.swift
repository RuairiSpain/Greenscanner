import Foundation

final class ScanStore: @unchecked Sendable {
    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("GreenSight", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("scans.json")
    }

    func load() -> [ScanRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let records = try? decoder.decode([ScanRecord].self, from: data) else { return [] }
        return records.sorted { $0.createdAt > $1.createdAt }
    }

    func save(_ records: [ScanRecord]) {
        guard let data = try? JSONEncoder.pretty.encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func export(_ record: ScanRecord) throws -> URL {
        let formatter = ISO8601DateFormatter()
        let safeDate = formatter.string(from: record.createdAt).replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GreenSight-\(safeDate).json")
        try JSONEncoder.pretty.encode(record).write(to: url, options: .atomic)
        return url
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
