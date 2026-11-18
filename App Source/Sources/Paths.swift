import Foundation

enum AppPaths {
    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DCBT Reader", isDirectory: true)
    }
    static var indexDir: URL { supportDir.appendingPathComponent("index", isDirectory: true) }
    static var semanticDir: URL { supportDir.appendingPathComponent("semantic", isDirectory: true) }
    /// Optional "Gaiji" folder (CBETA's supplementary font and glyph images).
    static var gaijiDir: URL? {
        let fm = FileManager.default
        for d in [Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Gaiji", isDirectory: true),
                  supportDir.appendingPathComponent("Gaiji", isDirectory: true)] where fm.fileExists(atPath: d.path) { return d }
        return nil
    }
    /// Optional "Dictionaries" folder (StarDict dictionaries, one sub-folder each).
    static var dictionariesDir: URL? {
        let fm = FileManager.default
        for d in [Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Dictionaries", isDirectory: true),
                  supportDir.appendingPathComponent("Dictionaries", isDirectory: true)] where fm.fileExists(atPath: d.path) { return d }
        return nil
    }
    /// Optional "Language model" folder: beside the app, or in Application Support.
    static var modelDir: URL? {
        let fm = FileManager.default
        for d in [Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Language model", isDirectory: true),
                  supportDir.appendingPathComponent("Language model", isDirectory: true)] where fm.fileExists(atPath: d.path) { return d }
        return nil
    }
}
