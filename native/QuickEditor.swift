import AppKit
import SwiftUI

/// A small editor for quick, one-off edits from a project's changes: line numbers, syntax colors
/// (the diff's highlighter), find (⌘F) and save (⌘S). Text files up to a few MB in UTF-8; line
/// endings are kept as they were. A save checks that nobody changed the file on disk since it
/// was opened, and closing with unsaved changes asks first.
enum QuickEditor {
  static let maxBytes = 4 << 20
  private static var windows: [URL: NSWindow] = [:]

  static func open(_ url: URL) {
    let url = url.standardizedFileURL
    if let w = windows[url] {
      w.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }
    let doc: EditorDocument
    switch EditorDocument.load(url) {
    case .success(let d): doc = d
    case .failure(let failure):
      let alert = NSAlert()
      alert.messageText = L("Não dá para editar aqui")
      alert.informativeText = failure.message
      alert.addButton(withTitle: L("Abrir no app padrão"))
      alert.addButton(withTitle: L("Cancelar"))
      if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
      return
    }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    window.title = url.lastPathComponent
    window.representedURL = url
    window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 480, height: 320)
    window.setFrameAutosaveName("quick-editor")
    let delegate = EditorWindowDelegate(doc: doc) { windows[url] = nil }
    objc_setAssociatedObject(window, &EditorWindowDelegate.key, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    window.delegate = delegate
    window.contentView = NSHostingView(rootView: QuickEditorView(doc: doc))
    windows[url] = window
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}

/// The file being edited: its text, whether it changed, and what it was on disk when loaded.
final class EditorDocument: ObservableObject {
  let url: URL
  @Published var text: String { didSet { if text != saved { dirty = true } } }
  @Published private(set) var dirty = false
  @Published var message: (ok: Bool, text: String)?
  @Published var cursor = (line: 1, column: 1)
  private var saved: String
  private let crlf: Bool
  private var loadedModified: Date?
  let language: SyntaxHighlighter.Language

  private init(url: URL, text: String, crlf: Bool, modified: Date?) {
    self.url = url
    self.text = text
    saved = text
    self.crlf = crlf
    loadedModified = modified
    language = SyntaxHighlighter.language(for: url.path)
  }

  static func load(_ url: URL) -> Result<EditorDocument, DBError> {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
      return .failure(DBError(message: L("O arquivo não existe mais."))) }
    let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
    guard size <= QuickEditor.maxBytes else { return .failure(DBError(message: L("Arquivo grande demais para o editor rápido (%@).", formatBytes(Double(size))))) }
    guard let data = try? Data(contentsOf: url) else { return .failure(DBError(message: L("Não foi possível ler o arquivo."))) }
    if data.prefix(8000).contains(0) { return .failure(DBError(message: L("Parece um arquivo binário."))) }
    guard let raw = String(data: data, encoding: .utf8) else { return .failure(DBError(message: L("O arquivo não está em UTF-8."))) }
    let crlf = raw.contains("\r\n")
    let text = crlf ? raw.replacingOccurrences(of: "\r\n", with: "\n") : raw
    return .success(EditorDocument(url: url, text: text, crlf: crlf, modified: attrs[.modificationDate] as? Date))
  }

  /// Writes the file; `force` overwrites a version someone else saved meanwhile.
  @discardableResult func save(force: Bool = false) -> Bool {
    let current = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    if !force, let current, let loaded = loadedModified, current > loaded.addingTimeInterval(0.5) {
      let alert = NSAlert()
      alert.messageText = L("O arquivo mudou no disco")
      alert.informativeText = L("Outro programa salvou %@ depois que você abriu. Sobrescrever com a sua versão?", url.lastPathComponent)
      alert.addButton(withTitle: L("Sobrescrever"))
      alert.addButton(withTitle: L("Cancelar"))
      guard alert.runModal() == .alertFirstButtonReturn else { return false }
    }
    let out = crlf ? text.replacingOccurrences(of: "\n", with: "\r\n") : text
    do {
      try Data(out.utf8).write(to: url, options: .atomic)
      saved = text
      dirty = false
      loadedModified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
      message = (true, L("Salvo"))
      return true
    } catch {
      message = (false, error.localizedDescription)
      return false
    }
  }
}

private final class EditorWindowDelegate: NSObject, NSWindowDelegate {
  static var key = 0
  let doc: EditorDocument
  let closed: () -> Void
  init(doc: EditorDocument, closed: @escaping () -> Void) {
    self.doc = doc
    self.closed = closed
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard doc.dirty else { return true }
    let alert = NSAlert()
    alert.messageText = L("Salvar as alterações em %@?", doc.url.lastPathComponent)
    alert.addButton(withTitle: L("Salvar"))
    alert.addButton(withTitle: L("Descartar"))
    alert.addButton(withTitle: L("Cancelar"))
    switch alert.runModal() {
    case .alertFirstButtonReturn: return doc.save()
    case .alertSecondButtonReturn: return true
    default: return false
    }
  }
  func windowWillClose(_ notification: Notification) { closed() }
}

struct QuickEditorView: View {
  @ObservedObject var doc: EditorDocument
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "doc.text").foregroundStyle(.secondary)
        Text(Demo.enabled ? doc.url.lastPathComponent : abbreviateHome(doc.url.path)).font(.caption).lineLimit(1).truncationMode(.head)
        if doc.dirty { Circle().fill(.orange).frame(width: 7, height: 7).help(L("Alterações não salvas")) }
        Spacer()
        if let m = doc.message {
          Text(m.text).font(.caption).foregroundStyle(m.ok ? Color.green : .red).lineLimit(1)
        }
        Button(L("Abrir no editor externo")) { CodeEditor.open(doc.url, external: true) }.controlSize(.small)
        Button(L("Salvar")) { doc.save() }
          .keyboardShortcut("s", modifiers: .command).controlSize(.small).disabled(!doc.dirty)
      }
      .padding(.horizontal, 10).padding(.vertical, 6)
      Divider()
      CodeTextView(doc: doc)
      Divider()
      HStack {
        Text(L("Linha %@, coluna %@", "\(doc.cursor.line)", "\(doc.cursor.column)")).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        Spacer()
        Text("UTF-8").font(.caption).foregroundStyle(.secondary)
      }
      .padding(.horizontal, 10).padding(.vertical, 4)
    }
  }
}

/// NSTextView (TextKit 1, for the line-number ruler) bound to the document.
struct CodeTextView: NSViewRepresentable {
  @ObservedObject var doc: EditorDocument

  func makeCoordinator() -> Coordinator { Coordinator(doc: doc) }

  func makeNSView(context: Context) -> NSScrollView {
    let storage = NSTextStorage()
    let layout = NSLayoutManager()
    storage.addLayoutManager(layout)
    let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
    container.widthTracksTextView = false
    layout.addTextContainer(container)
    let text = NSTextView(frame: .zero, textContainer: container)
    text.isRichText = false
    text.allowsUndo = true
    text.usesFindBar = true
    text.isIncrementalSearchingEnabled = true
    text.isAutomaticQuoteSubstitutionEnabled = false
    text.isAutomaticDashSubstitutionEnabled = false
    text.isAutomaticTextReplacementEnabled = false
    text.isAutomaticSpellingCorrectionEnabled = false
    text.isContinuousSpellCheckingEnabled = false
    text.smartInsertDeleteEnabled = false
    text.font = Coordinator.font
    text.textColor = .textColor
    text.backgroundColor = .textBackgroundColor
    text.insertionPointColor = .controlAccentColor
    let scroll = CodeScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.autohidesScrollers = true
    // Lines do not wrap: the text view grows sideways, starting at the clip view's origin.
    text.minSize = NSSize(width: 0, height: scroll.contentSize.height)
    text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    text.isHorizontallyResizable = true
    text.isVerticallyResizable = true
    text.autoresizingMask = [.width, .height]
    text.frame = NSRect(origin: .zero, size: scroll.contentSize)
    text.textContainerInset = NSSize(width: 4, height: 6)
    // Inside the (flipped) clip view before the text goes in: outside it, a growing text view
    // keeps its top edge and ends up with the file's last lines at the top.
    scroll.documentView = text
    text.string = doc.text
    // Setting the string leaves the cursor at the end; open at the first line instead.
    text.setSelectedRange(NSRange(location: 0, length: 0))
    text.delegate = context.coordinator
    let ruler = LineNumberRuler(textView: text)
    scroll.verticalRulerView = ruler
    scroll.hasVerticalRuler = true
    scroll.rulersVisible = true
    scroll.tile()
    ruler.attach(to: scroll)
    context.coordinator.textView = text
    context.coordinator.ruler = ruler
    context.coordinator.scroll = scroll
    context.coordinator.highlightAll()
    // Lay the whole file out now, so the text view does not keep growing (and moving the view)
    // after it is on screen.
    layout.ensureLayout(for: container)
    text.sizeToFit()
    text.setFrameOrigin(.zero)
    DispatchQueue.main.async {
      text.window?.makeFirstResponder(text)
      text.setSelectedRange(NSRange(location: 0, length: 0))
    }
    // SwiftUI resizes the view a few times while the window settles; stay at the top until the
    // user moves (scroll, click, keys) or, at the latest, a few seconds later.
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { scroll.keepsTop = false }
    return scroll
  }

  func updateNSView(_ nsView: NSScrollView, context: Context) {}

  final class Coordinator: NSObject, NSTextViewDelegate {
    static let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    let doc: EditorDocument
    weak var textView: NSTextView?
    weak var ruler: LineNumberRuler?
    weak var scroll: CodeScrollView?
    private var pending: DispatchWorkItem?
    init(doc: EditorDocument) { self.doc = doc }

    func textDidChange(_ notification: Notification) {
      guard let text = textView else { return }
      doc.text = text.string
      doc.message = nil
      ruler?.invalidateLines()
      pending?.cancel()
      // Re-color the edited paragraphs right away and the whole file shortly after.
      if let range = text.selectedRanges.first?.rangeValue { highlight(paragraphOf: range) }
      let work = DispatchWorkItem { [weak self] in self?.highlightAll() }
      pending = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      guard let text = textView, let range = text.selectedRanges.first?.rangeValue else { return }
      if range.location != 0 || range.length != 0 { scroll?.keepsTop = false }
      let ns = text.string as NSString
      let upTo = ns.substring(to: min(range.location, ns.length))
      let line = upTo.reduce(into: 1) { n, c in if c == "\n" { n += 1 } }
      let column = upTo.count - (upTo.lastIndex(of: "\n").map { upTo.distance(from: upTo.startIndex, to: $0) + 1 } ?? 0) + 1
      if doc.cursor != (line, column) { doc.cursor = (line, column) }
    }

    func highlightAll() {
      guard let text = textView, let storage = text.textStorage else { return }
      color(storage, range: NSRange(location: 0, length: storage.length))
    }
    private func highlight(paragraphOf range: NSRange) {
      guard let text = textView, let storage = text.textStorage else { return }
      let paragraph = (storage.string as NSString).paragraphRange(for: range)
      color(storage, range: paragraph)
    }
    /// Base color plus token colors, line by line inside `range`.
    private func color(_ storage: NSTextStorage, range: NSRange) {
      let ns = storage.string as NSString
      guard range.location + range.length <= ns.length else { return }
      storage.beginEditing()
      storage.addAttributes([.foregroundColor: NSColor.textColor, .font: Self.font], range: range)
      if doc.language != .plain {
        ns.enumerateSubstrings(in: range, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
          let line = ns.substring(with: lineRange)
          let tokens = SyntaxHighlighter.tokens(line, self.doc.language)
          guard !tokens.isEmpty else { return }
          // Token offsets are unicode scalars; NSString ranges are UTF-16.
          var utf16: [Int] = [0]
          for scalar in line.unicodeScalars { utf16.append(utf16.last! + scalar.utf16.count) }
          for t in tokens where t.to <= utf16.count - 1 {
            let r = NSRange(location: lineRange.location + utf16[t.from], length: utf16[t.to] - utf16[t.from])
            storage.addAttribute(.foregroundColor, value: SyntaxHighlighter.nsColor(t.kind), range: r)
          }
        }
      }
      storage.endEditing()
    }
  }
}

/// Opens at the first line: while `keepsTop` (the window settling, until the user scrolls),
/// every re-tile goes back to the top-left corner. That corner is the clip view's smallest
/// allowed origin, not zero: the line-number ruler floats over the content as an inset.
final class CodeScrollView: NSScrollView {
  var keepsTop = true
  override func tile() {
    super.tile()
    toTop()
  }
  override func layout() {
    super.layout()
    toTop()
  }
  override func reflectScrolledClipView(_ clip: NSClipView) {
    super.reflectScrolledClipView(clip)
    toTop()
  }
  private var moving = false
  private func toTop() {
    guard keepsTop, !moving, contentView.bounds.width > 0 else { return }
    let far = NSRect(origin: NSPoint(x: -1e6, y: -1e6), size: contentView.bounds.size)
    let start = contentView.constrainBoundsRect(far).origin
    guard contentView.bounds.origin != start else { return }
    moving = true
    defer { moving = false }
    contentView.scroll(to: start)
    reflectScrolledClipView(contentView)
  }
  override func scrollWheel(with event: NSEvent) {
    keepsTop = false
    super.scrollWheel(with: event)
  }
}

/// Line numbers beside the text, for the visible lines only.
final class LineNumberRuler: NSRulerView {
  private weak var textView: NSTextView?
  private var lineStarts: [Int] = [0]
  init(textView: NSTextView) {
    self.textView = textView
    super.init(scrollView: nil, orientation: .verticalRuler)
    clientView = textView
    ruleThickness = 44
    invalidateLines()
  }
  /// Redraws the numbers as the text scrolls.
  func attach(to scroll: NSScrollView) {
    scroll.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
  }
  required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

  @objc private func redraw() { needsDisplay = true }

  func invalidateLines() {
    guard let text = textView?.string as NSString? else { return }
    var starts = [0]
    var i = 0
    while i < text.length {
      let r = text.range(of: "\n", options: [], range: NSRange(location: i, length: text.length - i))
      if r.location == NSNotFound { break }
      starts.append(r.location + 1)
      i = r.location + 1
    }
    lineStarts = starts
    let digits = max(3, String(starts.count).count)
    ruleThickness = CGFloat(digits) * 8 + 16
    needsDisplay = true
  }

  override func drawHashMarksAndLabels(in rect: NSRect) {
    guard let text = textView, let layout = text.layoutManager, let container = text.textContainer else { return }
    NSColor.textBackgroundColor.setFill()
    bounds.fill()
    let visible = text.visibleRect
    let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
    let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor,
    ]
    // First visible line by binary search over line starts.
    var lo = 0
    var hi = lineStarts.count - 1
    while lo < hi {
      let mid = (lo + hi + 1) / 2
      if lineStarts[mid] <= chars.location { lo = mid } else { hi = mid - 1 }
    }
    var line = lo
    let inset = text.textContainerInset.height
    while line < lineStarts.count, lineStarts[line] <= chars.location + chars.length {
      let start = lineStarts[line]
      let glyph = layout.glyphIndexForCharacter(at: min(start, max(0, (text.string as NSString).length - 1)))
      var lineRect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
      if (text.string as NSString).length == 0 { lineRect = NSRect(x: 0, y: 0, width: 0, height: 16) }
      let y = convert(NSPoint(x: 0, y: lineRect.minY + inset), from: text).y
      let label = "\(line + 1)" as NSString
      let size = label.size(withAttributes: attrs)
      label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y + (lineRect.height - size.height) / 2), withAttributes: attrs)
      line += 1
    }
  }
}
