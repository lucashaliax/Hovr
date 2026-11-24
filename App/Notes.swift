import AppKit

// MARK: - Colours

enum NoteColor {
    /// The note backgrounds offered in a note's menu.
    static let palette: [String] = [
        "#FF8A80", "#FFB774", "#FFE97A", "#A8E293", "#91D0F2", "#B8A8F6",
        "#F2A7D8", "#E3D4B8", "#C4C4C4", "#FFFFFF", "#1F1F1F",
    ]
    static let defaultHex = "#FFE97A"

    static func name(_ hex: String) -> String {
        let names = [String(localized: "Coral"), String(localized: "Peach"), String(localized: "Lemon"), String(localized: "Mint"),
                     String(localized: "Sky"), String(localized: "Lavender"), String(localized: "Rose"), String(localized: "Sand"),
                     String(localized: "Silver"), String(localized: "White"), String(localized: "Ink")]
        if let i = palette.firstIndex(of: hex.uppercased()) { return names[i] }
        return String(localized: "Custom")
    }

    static func color(_ hex: String?) -> NSColor {
        var s = (hex ?? defaultHex).trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return color(defaultHex) }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    static func hex(_ c: NSColor) -> String {
        let c = c.usingColorSpace(.sRGB) ?? c
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    static func isDark(_ c: NSColor) -> Bool {
        let c = c.usingColorSpace(.sRGB) ?? c
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent < 0.55
    }
}

// MARK: - Checkboxes

/// A checkbox in a note. In memory it knows its state; on disk the image's file name says it.
final class CheckboxAttachment: NSTextAttachment {
    var checked = false
}

/// Checkboxes are small image attachments; the file name inside the .rtfd says whether they're ticked.
enum Checkbox {
    private static var cache: [Bool: Data] = [:]

    static func attachment(_ on: Bool) -> NSTextAttachment {
        let data = png(on)
        let fw = FileWrapper(regularFileWithContents: data)
        fw.preferredFilename = on ? "hovr-check-on.png" : "hovr-check-off.png"
        let a = CheckboxAttachment(fileWrapper: fw)
        a.checked = on
        a.image = NSImage(data: data)
        a.image?.size = NSSize(width: 17, height: 17)
        a.bounds = CGRect(x: 0, y: -3.5, width: 17, height: 17)
        return a
    }

    static func string(_ on: Bool, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let s = NSMutableAttributedString(attachment: attachment(on))
        s.append(NSAttributedString(string: " ", attributes: attributes))
        s.addAttributes(attributes.filter { $0.key != .attachment }, range: NSRange(location: 0, length: 1))
        return s
    }

    static func state(_ a: NSTextAttachment) -> Bool? {
        if let c = a as? CheckboxAttachment { return c.checked }
        let name = a.fileWrapper?.preferredFilename ?? a.fileWrapper?.filename ?? ""
        if name.contains("check-on") { return true }
        if name.contains("check-off") { return false }
        return nil
    }

    private static func png(_ on: Bool) -> Data {
        if let d = cache[on] { return d }
        let px = 34
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: 17, height: 17)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let r = NSRect(x: 1, y: 1, width: 15, height: 15)
        if on {
            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: r).fill()
            let check = NSBezierPath()
            check.move(to: NSPoint(x: 5, y: 8.6))
            check.line(to: NSPoint(x: 7.6, y: 6))
            check.line(to: NSPoint(x: 12.2, y: 11))
            check.lineWidth = 1.9
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            NSColor.white.setStroke()
            check.stroke()
        } else {
            let ring = NSBezierPath(ovalIn: r.insetBy(dx: 0.6, dy: 0.6))
            ring.lineWidth = 1.3
            NSColor(white: 0.45, alpha: 0.6).setStroke()
            ring.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        let d = rep.representation(using: .png, properties: [:]) ?? Data()
        cache[on] = d
        return d
    }
}

// MARK: - Note card content

/// A note: a small header (close dot, checklist, ⋯ — drawn by the card) and a rich-text area.
final class NoteCardView: NSView {
    static let defaultSize = NSSize(width: 240, height: 240)
    static let header: CGFloat = 32

    let entryID: UUID
    private let scroll = NoteScrollView()
    let textView: NoteTextView
    private(set) var background: NSColor
    var onColorChange: (() -> Void)?
    private var saveWork: DispatchWorkItem?

    var isDark: Bool { NoteColor.isDark(background) }
    var chromeColor: NSColor { isDark ? .white : NSColor.black.withAlphaComponent(0.7) }
    var plainText: String { textView.string.replacingOccurrences(of: "\u{FFFC} ", with: "").replacingOccurrences(of: "\u{FFFC}", with: "") }

    init(entry: HistoryEntry) {
        entryID = entry.id
        background = NoteColor.color(entry.noteColor)
        // TextKit 1, so checkbox attachments can be clicked precisely.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        textView = NoteTextView(frame: .zero, textContainer: container)
        super.init(frame: .zero)
        wantsLayer = true

        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 4, height: 2)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.onChange = { [weak self] in self?.scheduleSave() }
        if let saved = History.shared.loadNote(entry.id) {
            storage.setAttributedString(saved)
            textView.normaliseCheckboxes()
        }

        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.borderType = .noBorder
        scroll.autoresizingMask = [.width, .height]
        addSubview(scroll)
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        scroll.frame = NSRect(x: 8, y: 6, width: bounds.width - 16, height: max(0, bounds.height - Self.header - 6))
        textView.frame.size.width = scroll.contentSize.width
    }

    func isTextArea(_ p: NSPoint) -> Bool { scroll.frame.contains(p) }
    var isEditing: Bool { window?.firstResponder === textView }

    /// The text scrolls when there's more than fits; otherwise two fingers move the card.
    func wantsScroll(_ event: NSEvent) -> Bool {
        guard let doc = scroll.documentView else { return false }
        return doc.frame.height > scroll.contentSize.height + 1 && isTextArea(convert(convert(event.locationInWindow, from: nil), to: self))
    }

    func scrollText(_ event: NSEvent) { scroll.scrollText(event) }

    func beginEditing() {
        window?.makeKey()
        window?.makeFirstResponder(textView)
        restartIdleTimer()
    }

    /// Fills a sample checklist (used by `-HovrPreview note` to check the look).
    func fillSample() {
        beginEditing()
        textView.toggleChecklist()
        textView.insertText("Water the plants", replacementRange: textView.selectedRange())
        textView.insertNewline(nil)
        textView.insertText("Buy milk", replacementRange: textView.selectedRange())
        textView.insertNewline(nil)
        textView.insertNewline(nil)
        textView.insertText("Weekend trip", replacementRange: textView.selectedRange())
        textView.insertNewline(nil)
        for word in ["-", " "] { textView.insertText(word, replacementRange: textView.selectedRange()) }
        textView.insertText("Passport", replacementRange: textView.selectedRange())
        textView.insertNewline(nil)
        textView.insertText("Charger", replacementRange: textView.selectedRange())
        textView.tickLine(containing: "Buy milk")
    }

    func toggleChecklist() {
        if window?.firstResponder !== textView { beginEditing(); textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0)) }
        textView.toggleChecklist()
    }

    func setColor(_ c: NSColor) {
        background = c
        History.shared.setNoteColor(entryID, NoteColor.hex(c))
        applyColors()
        onColorChange?()
    }

    private func applyColors() {
        layer?.backgroundColor = background.cgColor
        textView.baseColor = isDark ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.1, alpha: 1)
        textView.insertionPointColor = isDark ? .white : .black
    }

    // MARK: Ending editing on its own
    //
    // While a note is being edited, macOS animates its text cursor all the time (about 1% CPU), even when
    // you're working in another app. So editing ends after 20 s without typing, or when another of
    // Hovr's windows takes the keyboard.

    private var idleWork: DispatchWorkItem?
    private var resignObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let o = resignObserver { NotificationCenter.default.removeObserver(o) }
        resignObserver = nil
        guard let window else { return }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.endEditing() }
        }
    }

    func endEditing() {
        idleWork?.cancel()
        guard isEditing else { return }
        window?.makeFirstResponder(window?.contentView)
        saveNow()
    }

    private func restartIdleTimer() {
        idleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.endEditing() }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    private func scheduleSave() {
        restartIdleTimer()
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        guard let storage = textView.textStorage else { return }
        History.shared.saveNote(entryID, text: NSAttributedString(attributedString: storage))
    }
}

/// Passes two-finger scrolls to the card unless the text needs them.
final class NoteScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
    func scrollText(_ event: NSEvent) { super.scrollWheel(with: event) }
}

// MARK: - Text view

/// Rich text with lists: "[ ] " makes a checkbox, "- " or "* " a bullet, "1. " a numbered line;
/// Return continues the list and an empty item ends it. ⌘B ⌘I ⌘U ⇧⌘X, ⌘+ ⌘−, ⇧⌘V, Esc.
final class NoteTextView: NSTextView {
    var onChange: (() -> Void)?
    var baseColor: NSColor = .black { didSet { recolor() } }
    static let baseFont = NSFont.systemFont(ofSize: 14)

    private var normalAttributes: [NSAttributedString.Key: Any] {
        [.font: Self.baseFont, .foregroundColor: baseColor]
    }

    override init(frame: NSRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        typingAttributes = normalAttributes
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didChangeText() {
        super.didChangeText()
        onChange?()
        needsDisplay = true
    }

    // MARK: Placeholder

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.baseFont, .foregroundColor: baseColor.withAlphaComponent(0.4)]
        let origin = NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0), y: textContainerOrigin.y)
        (String(localized: "Type something…") as NSString).draw(at: origin, withAttributes: attrs)
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { window?.makeFirstResponder(window?.contentView); return } // Esc finishes editing
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return false }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let c = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if mods == .command {
            switch c {
            case "b": toggleTrait(.boldFontMask); return true
            case "i": toggleTrait(.italicFontMask); return true
            case "u": toggle(.underlineStyle); return true
            case "=", "+": changeSize(by: 2); return true
            case "-": changeSize(by: -2); return true
            case "c": copy(nil); return true
            case "x": cut(nil); return true
            case "v": paste(nil); return true
            case "a": selectAll(nil); return true
            case "z": undoManager?.undo(); return true
            default: return false
            }
        }
        if mods == [.command, .shift] {
            switch c {
            case "x": toggle(.strikethroughStyle); return true
            case "v": pasteAsPlainText(nil); return true
            case "z": undoManager?.redo(); return true
            default: return false
            }
        }
        return false
    }

    // MARK: Formatting

    private func toggleTrait(_ trait: NSFontTraitMask) {
        let fm = NSFontManager.shared
        let r = selectedRange()
        guard let storage = textStorage else { return }
        if r.length == 0 {
            let f = typingAttributes[.font] as? NSFont ?? Self.baseFont
            let on = fm.traits(of: f).contains(trait)
            typingAttributes[.font] = on ? fm.convert(f, toNotHaveTrait: trait) : fm.convert(f, toHaveTrait: trait)
            return
        }
        let first = storage.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont ?? Self.baseFont
        let on = fm.traits(of: first).contains(trait)
        guard shouldChangeText(in: r, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: r) { value, sub, _ in
            let f = value as? NSFont ?? Self.baseFont
            storage.addAttribute(.font, value: on ? fm.convert(f, toNotHaveTrait: trait) : fm.convert(f, toHaveTrait: trait), range: sub)
        }
        storage.endEditing()
        didChangeText()
    }

    private func toggle(_ key: NSAttributedString.Key) {
        let r = selectedRange()
        guard let storage = textStorage else { return }
        let single = NSUnderlineStyle.single.rawValue
        if r.length == 0 {
            let on = (typingAttributes[key] as? Int ?? 0) != 0
            typingAttributes[key] = on ? 0 : single
            return
        }
        let on = (storage.attribute(key, at: r.location, effectiveRange: nil) as? Int ?? 0) != 0
        guard shouldChangeText(in: r, replacementString: nil) else { return }
        storage.addAttribute(key, value: on ? 0 : single, range: r)
        didChangeText()
    }

    private func changeSize(by delta: CGFloat) {
        let r = selectedRange()
        guard let storage = textStorage else { return }
        let target = r.length == 0 ? NSRange(location: 0, length: storage.length) : r
        guard target.length > 0 else {
            let f = typingAttributes[.font] as? NSFont ?? Self.baseFont
            typingAttributes[.font] = NSFontManager.shared.convert(f, toSize: min(max(f.pointSize + delta, 9), 48))
            return
        }
        guard shouldChangeText(in: target, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: target) { value, sub, _ in
            let f = value as? NSFont ?? Self.baseFont
            storage.addAttribute(.font, value: NSFontManager.shared.convert(f, toSize: min(max(f.pointSize + delta, 9), 48)), range: sub)
        }
        storage.endEditing()
        didChangeText()
    }

    /// New colours for a new background; ticked lines stay faded.
    private func recolor() {
        guard let storage = textStorage, storage.length > 0 else { typingAttributes[.foregroundColor] = baseColor; return }
        storage.beginEditing()
        storage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: storage.length)) { value, sub, _ in
            let faded = ((value as? NSColor)?.alphaComponent ?? 1) < 0.7
            storage.addAttribute(.foregroundColor, value: faded ? baseColor.withAlphaComponent(0.45) : baseColor, range: sub)
        }
        storage.endEditing()
        typingAttributes[.foregroundColor] = baseColor
        needsDisplay = true
    }

    // MARK: Lists

    private var ns: NSString { string as NSString }

    private func paragraph(at location: Int) -> NSRange {
        ns.paragraphRange(for: NSRange(location: min(location, ns.length), length: 0))
    }

    private func checkbox(at index: Int) -> (NSTextAttachment, Bool)? {
        guard let storage = textStorage, index < storage.length, ns.character(at: index) == 0xFFFC,
              let a = storage.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment,
              let state = Checkbox.state(a) else { return nil }
        return (a, state)
    }

    private func numberPrefix(_ line: String) -> (Int, String)? {
        guard let m = line.range(of: #"^(\d{1,3})([.)]) "#, options: .regularExpression) else { return nil }
        let token = String(line[m])
        let digits = token.prefix { $0.isNumber }
        return (Int(digits) ?? 1, String(token.dropFirst(digits.count).prefix(1)))
    }

    /// Fresh attributes for a new line (no strikethrough, normal colour).
    private func resetTyping() {
        var a = typingAttributes
        a[.strikethroughStyle] = 0
        a[.foregroundColor] = baseColor
        typingAttributes = a
    }

    override func insertNewline(_ sender: Any?) {
        let sel = selectedRange()
        let para = paragraph(at: sel.location)
        let line = ns.substring(with: para).trimmingCharacters(in: .newlines)
        if checkbox(at: para.location) != nil {
            let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
            if body.isEmpty { removePrefix(in: para, length: min(2, para.length)); return }
            super.insertNewline(sender)
            resetTyping()
            insertAttributed(Checkbox.string(false, attributes: typingAttributes))
            return
        }
        if line.hasPrefix("• ") {
            if line.count <= 2 { removePrefix(in: para, length: 2); return }
            super.insertNewline(sender)
            insertText("• ", replacementRange: selectedRange())
            return
        }
        if let (n, sep) = numberPrefix(line) {
            if line.count <= "\(n)\(sep) ".count { removePrefix(in: para, length: "\(n)\(sep) ".count); return }
            super.insertNewline(sender)
            insertText("\(n + 1)\(sep) ", replacementRange: selectedRange())
            return
        }
        super.insertNewline(sender)
        resetTyping()
    }

    private func removePrefix(in para: NSRange, length: Int) {
        let r = NSRange(location: para.location, length: length)
        guard shouldChangeText(in: r, replacementString: "") else { return }
        textStorage?.replaceCharacters(in: r, with: "")
        didChangeText()
        setSelectedRange(NSRange(location: para.location, length: 0))
        resetTyping()
    }

    private func insertAttributed(_ s: NSAttributedString) {
        let r = selectedRange()
        guard shouldChangeText(in: r, replacementString: s.string) else { return }
        textStorage?.replaceCharacters(in: r, with: s)
        didChangeText()
        setSelectedRange(NSRange(location: r.location + s.length, length: 0))
    }

    override func insertText(_ text: Any, replacementRange: NSRange) {
        super.insertText(text, replacementRange: replacementRange)
        guard (text as? String) == " " else { return }
        // Markdown-like shortcuts typed at the start of a line.
        let caret = selectedRange().location
        let para = paragraph(at: caret)
        let typed = ns.substring(with: NSRange(location: para.location, length: caret - para.location))
        let prefixRange = NSRange(location: para.location, length: caret - para.location)
        switch typed {
        case "[ ] ", "[] ":
            replace(prefixRange, with: Checkbox.string(false, attributes: typingAttributes))
        case "[x] ", "[X] ":
            replace(prefixRange, with: Checkbox.string(true, attributes: typingAttributes))
        case "- ", "* ":
            replace(prefixRange, with: NSAttributedString(string: "• ", attributes: typingAttributes))
        default: break
        }
    }

    private func replace(_ r: NSRange, with s: NSAttributedString) {
        guard shouldChangeText(in: r, replacementString: s.string) else { return }
        textStorage?.replaceCharacters(in: r, with: s)
        didChangeText()
        setSelectedRange(NSRange(location: r.location + s.length, length: 0))
    }

    /// The checklist button: adds checkboxes to the selected lines, or removes them if all have one.
    func toggleChecklist() {
        guard let storage = textStorage else { return }
        let sel = selectedRange()
        var paras: [NSRange] = []
        var loc = paragraph(at: sel.location).location
        let end = sel.location + sel.length
        repeat {
            let p = paragraph(at: loc)
            paras.append(p)
            loc = NSMaxRange(p)
        } while loc < end && loc < ns.length
        if storage.length == 0 { paras = [NSRange(location: 0, length: 0)] }
        let allChecked = paras.allSatisfy { checkbox(at: $0.location) != nil }
        undoManager?.beginUndoGrouping()
        for p in paras.reversed() {
            if allChecked {
                let len = (p.length >= 2 && ns.character(at: p.location + 1) == 0x20) ? 2 : 1
                replace(NSRange(location: p.location, length: len), with: NSAttributedString())
            } else if checkbox(at: p.location) == nil {
                var strip = 0
                let line = ns.substring(with: p)
                if line.hasPrefix("• ") { strip = 2 }
                replace(NSRange(location: p.location, length: strip), with: Checkbox.string(false, attributes: normalAttributes))
            }
        }
        undoManager?.endUndoGrouping()
        let p = paragraph(at: min(sel.location, ns.length))
        let lineEnd = NSMaxRange(p) - (ns.substring(with: p).hasSuffix("\n") ? 1 : 0)
        setSelectedRange(NSRange(location: max(lineEnd, p.location), length: 0))
    }

    /// Clicking a checkbox ticks it (the line gets struck through and faded) or unticks it.
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let lm = layoutManager, let tc = textContainer {
            let local = NSPoint(x: p.x - textContainerOrigin.x, y: p.y - textContainerOrigin.y)
            let glyph = lm.glyphIndex(for: local, in: tc)
            let rect = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc).insetBy(dx: -3, dy: -3)
            let idx = lm.characterIndexForGlyph(at: glyph)
            if rect.contains(local), let (_, on) = checkbox(at: idx) {
                setChecked(!on, at: idx)
                return
            }
        }
        super.mouseDown(with: event)
    }

    private func setChecked(_ on: Bool, at index: Int) {
        guard let storage = textStorage else { return }
        let para = paragraph(at: index)
        guard shouldChangeText(in: para, replacementString: nil) else { return }
        storage.beginEditing()
        let keep = storage.attributes(at: index, effectiveRange: nil).filter { $0.key != .attachment }
        let box = NSMutableAttributedString(attachment: Checkbox.attachment(on))
        box.addAttributes(keep, range: NSRange(location: 0, length: 1))
        storage.replaceCharacters(in: NSRange(location: index, length: 1), with: box)
        let body = NSRange(location: index + 1, length: max(0, NSMaxRange(para) - index - 1))
        if body.length > 0 {
            storage.addAttribute(.strikethroughStyle, value: on ? NSUnderlineStyle.single.rawValue : 0, range: body)
            storage.addAttribute(.foregroundColor, value: on ? baseColor.withAlphaComponent(0.45) : baseColor, range: body)
        }
        storage.endEditing()
        didChangeText()
    }

    /// Ticks the checkbox on the line containing `text` (preview helper).
    func tickLine(containing text: String) {
        let r = ns.range(of: text)
        guard r.location != NSNotFound else { return }
        let para = paragraph(at: r.location)
        if checkbox(at: para.location) != nil { setChecked(true, at: para.location) }
    }

    /// Checkboxes loaded from disk get their size and image back.
    func normaliseCheckboxes() {
        guard let storage = textStorage else { return }
        var fixes: [(Int, Bool)] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, r, _ in
            if let a = value as? NSTextAttachment, let on = Checkbox.state(a) { fixes.append((r.location, on)) }
        }
        storage.beginEditing()
        for (i, on) in fixes {
            let keep = storage.attributes(at: i, effectiveRange: nil).filter { $0.key != .attachment }
            let box = NSMutableAttributedString(attachment: Checkbox.attachment(on))
            box.addAttributes(keep, range: NSRange(location: 0, length: 1))
            storage.replaceCharacters(in: NSRange(location: i, length: 1), with: box)
        }
        storage.endEditing()
    }
}
