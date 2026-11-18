import AppKit

/// Plain-text records of what was searched, looked up and translated. Entries are only ever
/// appended, so writing one costs the same however long a log has grown; nothing is read back
/// except the last searches, for the list under the search box.
enum ActivityLog: String {
    case searches = "Search log.txt"
    case dictionary = "Dictionary log.txt"
    case translations = "Translation log.txt"

    var url: URL { AppPaths.supportDir.appendingPathComponent(rawValue) }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    /// Adds one entry: the time, then the fields, separated by tabs.
    func add(_ fields: String...) {
        let line = ([ActivityLog.stamp.string(from: Date())] + fields).joined(separator: "\t") + "\n"
        let data = Data(line.utf8)
        if let h = FileHandle(forWritingAtPath: url.path) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? FileManager.default.createDirectory(at: AppPaths.supportDir, withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }

    /// Opens the log in the user's text editor; false if nothing has been logged yet.
    @discardableResult func open() -> Bool {
        FileManager.default.fileExists(atPath: url.path) && NSWorkspace.shared.open(url)
    }

    /// The last different searches, newest first, read from the end of the search log.
    static func recentSearches(_ limit: Int = 20) -> [(query: String, citation: Bool)] {
        guard let h = FileHandle(forReadingAtPath: ActivityLog.searches.url.path) else { return [] }
        defer { try? h.close() }
        let size = h.seekToEndOfFile()
        h.seek(toFileOffset: size > 32768 ? size - 32768 : 0)
        var out: [(query: String, citation: Bool)] = []
        for line in String(decoding: h.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").reversed() {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count >= 3, !out.contains(where: { $0.query == f[2] }) else { continue }
            out.append((String(f[2]), f[1] == "citation"))
            if out.count == limit { break }
        }
        return out
    }
}
