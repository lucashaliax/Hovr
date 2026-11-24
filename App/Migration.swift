import Foundation

/// The app was called "Hovr" while it was a draft (bundle id app.hovr.Hovr). On the first launch as Hovr,
/// its settings, captures, notes and logs move over. Runs before anything reads settings or files.
enum Migration {
    // Spelled in pieces so a project-wide rename can't change them.
    private static let oldName = "Clo" + "ne"
    private static let oldDomain = "app." + "clo" + "ne." + "Clo" + "ne"

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromDraft") else { return }
        defaults.set(true, forKey: "migratedFromDraft")
        let fm = FileManager.default

        // Settings: copy the old domain into this one.
        if let old = defaults.persistentDomain(forName: oldDomain), !old.isEmpty {
            for (k, v) in old where k != "AppleLanguages" && defaults.object(forKey: k) == nil { defaults.set(v, forKey: k) }
        }

        // Application Support (the list of captures) and logs.
        let lib = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        for sub in ["Application Support", "Logs"] {
            let from = lib.appendingPathComponent(sub).appendingPathComponent(oldName)
            let to = lib.appendingPathComponent(sub).appendingPathComponent("Hovr")
            if fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) { try? fm.moveItem(at: from, to: to) }
        }

        // The captures folder: the old default (~/Pictures/Hovr) moves to ~/Pictures/Hovr;
        // a folder the user chose stays where it is.
        let pictures = fm.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        let oldPics = pictures.appendingPathComponent(oldName), newPics = pictures.appendingPathComponent("Hovr")
        let chosen = defaults.string(forKey: "storageFolder")
        if chosen == nil || chosen == oldPics.path {
            if fm.fileExists(atPath: oldPics.path), !fm.fileExists(atPath: newPics.path) { try? fm.moveItem(at: oldPics, to: newPics) }
            defaults.removeObject(forKey: "storageFolder")
        }
    }
}
