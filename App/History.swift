import AppKit
import ImageIO
import UniformTypeIdentifiers

struct HistoryEntry: Codable, Identifiable, Hashable {
    let id: UUID
    /// Capture time; for notes, the last edit (Recents keeps them counted from there).
    var date: Date
    /// Size in pixels.
    let width: Int
    let height: Int
    /// Pixels per point of the screen it came from, so it opens at its original size.
    let scale: CGFloat
    /// Text read from the image: set right away for Text captures, later for images when asked.
    var text: String?
    /// Captured in Text mode (shown with a text badge).
    var isTextCapture: Bool
    /// File name in the captures folder ("Hovr 2026-11-23 at 19.45.12.png"); nil for early captures named by id.
    var fileName: String?
    /// Bundle id of the app that was in front when the capture was taken (shown on docked cards).
    var sourceApp: String?
    /// A note card (rich text in `<name>.rtfd`) instead of an image.
    var isNote: Bool?
    /// Note background, as hex ("#FFE97A").
    var noteColor: String?

    var note: Bool { isNote == true }

    var imageName: String { fileName ?? "\(id.uuidString).png" }
    /// Text captures also keep their text next to the image.
    var textName: String { (imageName as NSString).deletingPathExtension + ".txt" }

    var pointSize: NSSize { NSSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale) }
}

/// Every capture ("Recents"), kept for a few days (7 by default, or forever), then deleted.
/// Images (and the text of Text captures) go to a folder the user can choose, ~/Pictures/Hovr by default;
/// the list lives in ~/Library/Application Support/Hovr/index.json.
@MainActor
final class History: ObservableObject {
    static let shared = History()

    /// Newest first.
    @Published private(set) var entries: [HistoryEntry] = []
    @Published private(set) var folder: URL

    private let indexURL: URL
    private let thumbnails = NSCache<NSUUID, NSImage>()
    /// Images not yet written to disk, so they can be used right away.
    private var pending: [UUID: CGImage] = [:]

    static var defaultFolder: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Hovr", isDirectory: true)
    }

    private init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Hovr", isDirectory: true)
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        indexURL = support.appendingPathComponent("index.json")
        folder = UserDefaults.standard.string(forKey: "storageFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Self.defaultFolder
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

        // Drafts before 1.0 kept everything in Application Support/Hovr/History: move it to the folder.
        let legacy = support.appendingPathComponent("History", isDirectory: true)
        if let data = try? Data(contentsOf: legacy.appendingPathComponent("index.json")),
           let old = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            for e in old { try? fm.moveItem(at: legacy.appendingPathComponent(e.imageName), to: folder.appendingPathComponent(e.imageName)) }
            try? data.write(to: indexURL, options: .atomic)
            try? fm.removeItem(at: legacy)
        }

        if let data = try? Data(contentsOf: indexURL),
           let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            // Captures deleted in Finder disappear from Recents too.
            entries = saved.filter { fm.fileExists(atPath: folder.appendingPathComponent($0.imageName).path) }
                .sorted { $0.date > $1.date }
        }
        // Early captures were named by id; give them readable names.
        var renamed = false
        for i in entries.indices where entries[i].fileName == nil {
            let name = newFileName(for: entries[i].date)
            if (try? fm.moveItem(at: folder.appendingPathComponent(entries[i].imageName),
                                 to: folder.appendingPathComponent(name))) != nil {
                entries[i].fileName = name
                renamed = true
            }
        }
        if renamed { save() }
        thumbnails.countLimit = 200
        prune()
    }

    func fileURL(_ id: UUID) -> URL {
        folder.appendingPathComponent(entry(id)?.imageName ?? "\(id.uuidString).png")
    }

    private static let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    private func newFileName(for date: Date, prefix: String = "Hovr", ext: String = "png") -> String {
        let base = "\(prefix) \(Self.nameFormatter.string(from: date))"
        var name = base + "." + ext, n = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "\(base) \(n).\(ext)"; n += 1
        }
        return name
    }

    // MARK: Notes

    /// A new, empty note (saved as `Hovr Note <date>.rtfd` in the captures folder).
    func addNote(color: String) -> HistoryEntry {
        let date = Date()
        let entry = HistoryEntry(id: UUID(), date: date, width: 0, height: 0, scale: 1, text: "", isTextCapture: false,
                                 fileName: newFileName(for: date, prefix: "Hovr Note", ext: "rtfd"),
                                 sourceApp: nil, isNote: true, noteColor: color)
        entries.insert(entry, at: 0)
        save()
        return entry
    }

    func loadNote(_ id: UUID) -> NSAttributedString? {
        guard let e = entry(id), e.note else { return nil }
        let url = folder.appendingPathComponent(e.imageName)
        return try? NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtfd],
                                       documentAttributes: nil)
    }

    /// Writes the note and moves it to the top of Recents.
    func saveNote(_ id: UUID, text: NSAttributedString) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        let url = folder.appendingPathComponent(entries[i].imageName)
        if let wrapper = try? text.fileWrapper(from: NSRange(location: 0, length: text.length),
                                               documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]) {
            try? wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
        }
        entries[i].text = text.string.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        entries[i].date = Date()
        let e = entries.remove(at: i)
        entries.insert(e, at: 0)
        save()
    }

    func setNoteColor(_ id: UUID, _ hex: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].noteColor = hex
        save()
    }

    @discardableResult
    func add(image: CGImage, scale: CGFloat, text: String?, sourceApp: String? = nil) -> HistoryEntry {
        let date = Date()
        let entry = HistoryEntry(id: UUID(), date: date, width: image.width, height: image.height, scale: scale,
                                 text: text, isTextCapture: text != nil, fileName: newFileName(for: date),
                                 sourceApp: sourceApp)
        entries.insert(entry, at: 0)
        pending[entry.id] = image
        let url = folder.appendingPathComponent(entry.imageName)
        let textURL = folder.appendingPathComponent(entry.textName)
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            Self.writePNG(image, to: url, scale: scale)
            if let text, !text.isEmpty { try? text.write(to: textURL, atomically: true, encoding: .utf8) }
            await MainActor.run { _ = History.shared.pending.removeValue(forKey: entry.id) }
        }
        prune()
        save()
        return entry
    }

    func entry(_ id: UUID) -> HistoryEntry? { entries.first { $0.id == id } }

    func image(for id: UUID) -> CGImage? {
        if let img = pending[id] { return img }
        if entry(id)?.note == true { return nil }
        guard let src = CGImageSourceCreateWithURL(fileURL(id) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Small image for lists, decoded at the size needed and cached.
    func thumbnail(for id: UUID, maxPixels: Int = 480) -> NSImage? {
        if let cached = thumbnails.object(forKey: id as NSUUID) { return cached }
        if entry(id)?.note == true { return nil }
        let cg: CGImage?
        if let img = pending[id] {
            cg = img
        } else if let src = CGImageSourceCreateWithURL(fileURL(id) as CFURL, nil) {
            cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ] as CFDictionary)
        } else {
            cg = nil
        }
        guard let cg else { return nil }
        let img = NSImage(cgImage: cg, size: .zero)
        thumbnails.setObject(img, forKey: id as NSUUID)
        return img
    }

    /// Text of an entry, reading it from the image the first time.
    func text(for id: UUID) async -> String? {
        if let t = entry(id)?.text { return t }
        guard let img = image(for: id) else { return nil }
        let t = await OCR.recognize(img) ?? ""
        if let i = entries.firstIndex(where: { $0.id == id }) {
            entries[i].text = t
            save()
        }
        return t
    }

    private func removeFiles(_ e: HistoryEntry) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(e.imageName))
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(e.textName))
    }

    func delete(_ id: UUID) {
        if let e = entry(id) { removeFiles(e) }
        entries.removeAll { $0.id == id }
        thumbnails.removeObject(forKey: id as NSUUID)
        save()
    }

    /// Deletes every capture except those open as cards on screen.
    func clear() {
        let keep = entries.filter { CardManager.shared.isOpen($0.id) }
        for e in entries where !CardManager.shared.isOpen(e.id) { removeFiles(e) }
        entries = keep
        thumbnails.removeAllObjects()
        save()
    }

    /// Moves every capture to a new folder and keeps saving there.
    func moveFolder(to newFolder: URL) {
        let fm = FileManager.default
        guard newFolder.standardizedFileURL != folder.standardizedFileURL else { return }
        try? fm.createDirectory(at: newFolder, withIntermediateDirectories: true)
        for e in entries {
            for name in [e.imageName, e.textName] {
                let src = folder.appendingPathComponent(name)
                guard fm.fileExists(atPath: src.path) else { continue }
                try? fm.moveItem(at: src, to: newFolder.appendingPathComponent(name))
            }
        }
        // Remove the old folder if nothing else is left in it.
        if (try? fm.contentsOfDirectory(atPath: folder.path).filter { $0 != ".DS_Store" })?.isEmpty == true {
            try? fm.removeItem(at: folder)
        }
        folder = newFolder
        UserDefaults.standard.set(newFolder.path, forKey: "storageFolder")
    }

    /// Bytes used by the captures in the folder.
    func storageSize() -> Int64 {
        func size(_ url: URL) -> Int64 {
            let keys: Set<URLResourceKey> = [.fileSizeKey, .isDirectoryKey]
            guard let v = try? url.resourceValues(forKeys: keys) else { return 0 }
            if v.isDirectory == true {
                let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
                return (files?.allObjects as? [URL] ?? []).reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            }
            return Int64(v.fileSize ?? 0)
        }
        return entries.reduce(0) { $0 + size(folder.appendingPathComponent($1.imageName)) + size(folder.appendingPathComponent($1.textName)) }
    }

    /// Deletes captures older than the chosen number of days, and stray files.
    func prune() {
        let days = UserDefaults.standard.integer(forKey: "historyDays")
        guard days > 0 else { return } // "Never"
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let old = entries.filter { $0.date < cutoff }
        guard !old.isEmpty else { return }
        for e in old where !CardManager.shared.isOpen(e.id) {
            entries.removeAll { $0.id == e.id }
            thumbnails.removeObject(forKey: e.id as NSUUID)
            removeFiles(e)
        }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    nonisolated static func writePNG(_ image: CGImage, to url: URL, scale: CGFloat) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        let dpi = 72 * scale
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }
}
