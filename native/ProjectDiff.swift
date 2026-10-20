import AppKit
import SwiftUI

struct DiffLineData: Decodable, Equatable {
  let kind: String
  let old: Int?
  let new: Int?
  let text: String
}
struct DiffHunkData: Decodable, Equatable {
  let old_start: Int
  let old_len: Int
  let new_start: Int
  let new_len: Int
  let section: String
  let lines: [DiffLineData]
}
struct FileDiffData: Decodable, Equatable {
  let path: String
  let orig_path: String?
  let new_file: Bool
  let deleted: Bool
  let binary: Bool
  let added: Int
  let removed: Int
  let hunks: [DiffHunkData]
  let truncated: Bool
}
struct FileDiffList: Decodable { let files: [FileDiffData] }

/// What a gutter bar says about a line, as in Zed: added, removed, or part of a block where
/// lines were both removed and added (modified).
enum DiffMark { case none, added, removed, modified }

/// A diff line ready to draw: highlighted text and its gutter mark.
struct RenderedLine: Identifiable {
  let id: Int
  let kind: Character
  let number: Int?
  let text: AttributedString
  let mark: DiffMark
}
/// A file's diff ready to draw. `gaps[i]` is how many unchanged lines come before hunk i;
/// `columns` is the widest line (a tab counts as 4).
struct RenderedFile: Identifiable {
  let data: FileDiffData
  let hunks: [[RenderedLine]]
  let gaps: [Int]
  let columns: Int
  var id: String { data.path }
}

enum DiffRenderer {
  static func render(_ file: FileDiffData) -> RenderedFile {
    let lang = SyntaxHighlighter.language(for: file.path)
    var counter = 0
    var gaps: [Int] = []
    var previousEnd = 1
    let hunks = file.hunks.map { hunk -> [RenderedLine] in
      let start = max(hunk.new_start, 1)
      gaps.append(max(0, start - previousEnd))
      previousEnd = hunk.new_start + hunk.new_len
      let marks = marks(hunk.lines.map(\.kind))
      return hunk.lines.enumerated().map { i, line in
        counter += 1
        let kind = Character(line.kind.isEmpty ? " " : line.kind)
        return RenderedLine(
          id: counter, kind: kind, number: kind == "-" ? nil : line.new,
          text: Demo.enabled ? AttributedString(String(repeating: "•", count: min(line.text.count, 40))) : SyntaxHighlighter.highlight(line.text, lang),
          mark: marks[i])
      }
    }
    let columns = file.hunks.flatMap(\.lines).map { $0.text.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } }.max() ?? 0
    return RenderedFile(data: file, hunks: hunks, gaps: gaps, columns: Demo.enabled ? min(columns, 40) : columns)
  }

  /// A run of changed lines with both removals and additions is "modified" (yellow).
  static func marks(_ kinds: [String]) -> [DiffMark] {
    var out = [DiffMark](repeating: .none, count: kinds.count)
    var i = 0
    while i < kinds.count {
      guard kinds[i] != " " && !kinds[i].isEmpty else {
        i += 1
        continue
      }
      var j = i
      while j < kinds.count && (kinds[j] == "+" || kinds[j] == "-") { j += 1 }
      let run = kinds[i..<j]
      let both = run.contains("+") && run.contains("-")
      for k in i..<j { out[k] = both ? .modified : kinds[k] == "+" ? .added : .removed }
      i = j
    }
    return out
  }
}

/// Small per-line highlighter: comments, strings, numbers, keywords, types and `$variables`,
/// for the usual languages. Lines are highlighted on their own (a block comment that spans
/// lines is not followed), which is enough for reading a diff.
enum SyntaxHighlighter {
  enum Language { case cLike, python, ruby, shell, php, markup, data, plain }
  static func language(for path: String) -> Language {
    switch (path as NSString).pathExtension.lowercased() {
    case "php": .php
    case "js", "jsx", "ts", "tsx", "mjs", "cjs", "vue", "svelte", "swift", "rs", "go", "java", "kt", "kts", "c", "h", "cc", "cpp", "hpp", "m", "mm", "cs", "dart", "scala", "css", "scss", "less", "groovy", "gradle":
      .cLike
    case "py": .python
    case "rb", "rake", "erb": .ruby
    case "sh", "bash", "zsh", "fish", "env": .shell
    case "html", "htm", "xml", "svg", "blade", "twig": .markup
    case "json", "yml", "yaml", "toml", "ini", "lock": .data
    default: (path as NSString).lastPathComponent == "Dockerfile" || (path as NSString).lastPathComponent == "Makefile" ? .shell : .plain
    }
  }
  private static let keywords: Set<String> = [
    "abstract", "and", "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "def", "default",
    "defer", "del", "do", "elif", "else", "elseif", "enum", "except", "export", "extends", "extension", "false", "final",
    "finally", "fn", "for", "foreach", "from", "func", "function", "go", "guard", "if", "impl", "implements", "import",
    "in", "include", "instanceof", "interface", "is", "let", "lambda", "match", "mod", "module", "mut", "namespace",
    "new", "nil", "None", "not", "null", "or", "package", "pass", "private", "protected", "pub", "public", "raise",
    "readonly", "require", "rescue", "return", "self", "Self", "static", "struct", "super", "switch", "this", "throw",
    "throws", "trait", "true", "True", "False", "try", "type", "typeof", "unless", "use", "val", "var", "void", "where",
    "while", "with", "yield", "end", "then", "fi", "esac", "done", "echo", "local", "export", "begin", "fun", "when",
    "override", "init", "deinit", "inout", "some", "any", "protocol", "internal", "fileprivate", "loop", "unsafe",
    "crate", "ref", "dyn", "chan", "select", "range", "map", "interface", "of", "undefined", "declare", "keyof",
  ]
  static let keyword = Color(red: 0.78, green: 0.47, blue: 0.87)
  static let string = Color(red: 0.6, green: 0.76, blue: 0.47)
  static let comment = Color.secondary
  static let number = Color(red: 0.82, green: 0.6, blue: 0.4)
  static let type = Color(red: 0.9, green: 0.75, blue: 0.48)
  static let variable = Color(red: 0.88, green: 0.42, blue: 0.46)

  private static func isWord(_ c: UInt32) -> Bool {
    (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127
  }
  private static func isDigit(_ c: UInt32) -> Bool { c >= 48 && c <= 57 }
  private static func isUpper(_ c: UInt32) -> Bool { c >= 65 && c <= 90 }

  enum TokenKind { case keyword, string, comment, number, type, variable }
  /// A colored stretch of a line, in unicode-scalar offsets.
  struct Token: Equatable {
    let from: Int
    let to: Int
    let kind: TokenKind
  }
  static func color(_ kind: TokenKind) -> Color {
    switch kind {
    case .keyword: keyword
    case .string: string
    case .comment: comment
    case .number: number
    case .type: type
    case .variable: variable
    }
  }
  /// The same palette for AppKit text (the quick editor).
  static func nsColor(_ kind: TokenKind) -> NSColor {
    switch kind {
    case .keyword: NSColor(red: 0.78, green: 0.47, blue: 0.87, alpha: 1)
    case .string: NSColor(red: 0.45, green: 0.66, blue: 0.32, alpha: 1)
    case .comment: .secondaryLabelColor
    case .number: NSColor(red: 0.82, green: 0.52, blue: 0.27, alpha: 1)
    case .type: NSColor(red: 0.78, green: 0.6, blue: 0.2, alpha: 1)
    case .variable: NSColor(red: 0.88, green: 0.42, blue: 0.46, alpha: 1)
    }
  }

  static func highlight(_ line: String, _ lang: Language) -> AttributedString {
    var out = AttributedString(line)
    for t in tokens(line, lang) {
      let start = out.unicodeScalars.index(out.startIndex, offsetBy: t.from)
      let end = out.unicodeScalars.index(out.startIndex, offsetBy: t.to)
      out[start..<end].foregroundColor = color(t.kind)
    }
    return out
  }

  static func tokens(_ line: String, _ lang: Language) -> [Token] {
    var out: [Token] = []
    guard lang != .plain, !line.isEmpty else { return out }
    // Code points as numbers: plain integer comparisons keep the type checker fast.
    let chars: [UInt32] = line.unicodeScalars.map(\.value)
    let n = chars.count
    let slash: UInt32 = 47, star: UInt32 = 42, hash: UInt32 = 35, lt: UInt32 = 60, bang: UInt32 = 33
    let dquote: UInt32 = 34, squote: UInt32 = 39, backtick: UInt32 = 96, backslash: UInt32 = 92
    let dollar: UInt32 = 36, at: UInt32 = 64, dot: UInt32 = 46, space: UInt32 = 32
    let colon: UInt32 = 58, equals: UInt32 = 61, lbrace: UInt32 = 123, rbrace: UInt32 = 125
    func paint(_ from: Int, _ to: Int, _ kind: TokenKind) { out.append(Token(from: from, to: to, kind: kind)) }
    let hashComments = lang == .python || lang == .ruby || lang == .shell || lang == .data || lang == .php
    let slashComments = lang != .data && lang != .markup
    var i = 0
    while i < n {
      let c = chars[i]
      let next: UInt32 = i + 1 < n ? chars[i + 1] : 0
      if (c == slash && next == slash && slashComments) || (c == hash && hashComments) || (lang == .markup && c == lt && next == bang) {
        paint(i, n, .comment)
        return out
      }
      if c == slash && next == star {
        var j = i + 2
        while j + 1 < n && !(chars[j] == star && chars[j + 1] == slash) { j += 1 }
        j = min(n, j + 2)
        paint(i, j, .comment)
        i = j
        continue
      }
      if c == dquote || c == squote || c == backtick {
        var j = i + 1
        while j < n && chars[j] != c {
          if chars[j] == backslash { j += 1 }
          j += 1
        }
        j = min(n, j + 1)
        paint(i, j, .string)
        i = j
        continue
      }
      if c == dollar && (lang == .php || lang == .shell) && (isWord(next) || next == lbrace) {
        var j = i + 1
        while j < n && (isWord(chars[j]) || chars[j] == lbrace || chars[j] == rbrace) { j += 1 }
        paint(i, j, .variable)
        i = j
        continue
      }
      if isDigit(c) && (i == 0 || !isWord(chars[i - 1])) {
        var j = i
        while j < n && (isWord(chars[j]) || chars[j] == dot) { j += 1 }
        paint(i, j, .number)
        i = j
        continue
      }
      if (isWord(c) && !isDigit(c)) || c == at {
        var j = i
        while j < n && (isWord(chars[j]) || chars[j] == at) { j += 1 }
        let word = String(String.UnicodeScalarView(chars[i..<j].compactMap(Unicode.Scalar.init)))
        if lang == .data {
          var k = j
          while k < n && chars[k] == space { k += 1 }
          if k < n && (chars[k] == colon || chars[k] == equals) { paint(i, j, .keyword) }
        } else if keywords.contains(word) {
          paint(i, j, .keyword)
        } else if isUpper(c) && j - i > 1 {
          paint(i, j, .type)
        }
        i = j
        continue
      }
      i += 1
    }
    return out
  }
}

/// Changes in the style of Zed's uncommitted-changes view: one pinned header per file (stage
/// checkbox, name, folder, +/−, Open), a gutter bar (green added, red removed, yellow modified),
/// new-side line numbers, tinted lines and the unchanged stretches folded into "⋯ N lines".
struct ZedDiffView: View {
  let files: [RenderedFile]?
  let empty: String
  let loading: Bool
  /// Whether a file is staged entirely (true), partly (nil) or not at all (false).
  let stagedState: (String) -> Bool?
  let toggleStage: (String, Bool) -> Void
  let expand: (String) -> Void
  let open: (String) -> Void
  let edit: (String) -> Void
  @ViewState private var collapsed: Set<String> = []
  @ViewState private var currentHunk = 0
  /// How far the diff is scrolled sideways: file headers follow it so their buttons stay in view.
  @ViewState private var scrollX: CGFloat = 0

  private var hunkIDs: [String] {
    (files ?? []).filter { !collapsed.contains($0.id) }.flatMap { f in f.hunks.indices.map { "\(f.id)#\($0)" } }
  }

  var body: some View {
    if let files, !files.isEmpty {
      ScrollViewReader { proxy in
        VStack(spacing: 0) {
          toolbar(files, proxy)
          Divider()
          GeometryReader { geo in
            ScrollView([.vertical, .horizontal]) {
              LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(files) { file in
                  Section {
                    if !collapsed.contains(file.id) { fileBody(file) }
                  } header: {
                    header(file).frame(width: geo.size.width, alignment: .leading).offset(x: scrollX)
                  }
                }
              }
              // A lazy stack only measures the rows on screen, so the 2D scroll view gets the
              // widest line's width explicitly; top-left because it centers shorter content.
              .frame(width: max(geo.size.width, contentWidth(files)), alignment: .topLeading)
              .frame(minHeight: geo.size.height, alignment: .topLeading)
              .textSelection(.enabled)
              .background(GeometryReader { g in Color.clear.preference(key: DiffScrollX.self, value: -g.frame(in: .named("diff")).minX) })
            }
            .coordinateSpace(name: "diff")
            .onPreferenceChange(DiffScrollX.self) { x in if scrollX != max(0, x) { scrollX = max(0, x) } }
          }
        }
      }
      .background(Color(nsColor: .textBackgroundColor))
    } else if files != nil || !loading {
      Text(empty).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private static let charWidth = ("M" as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]).width
  /// Gutter (bar, number, padding) plus the widest expanded file's text and its trailing padding.
  private func contentWidth(_ files: [RenderedFile]) -> CGFloat {
    let columns = files.filter { !collapsed.contains($0.id) }.map(\.columns).max() ?? 0
    return 3 + 46 + 12 + CGFloat(columns) * Self.charWidth + 24 + 8
  }

  private func toolbar(_ files: [RenderedFile], _ proxy: ScrollViewProxy) -> some View {
    let added = files.reduce(0) { $0 + $1.data.added }
    let removed = files.reduce(0) { $0 + $1.data.removed }
    return HStack(spacing: 10) {
      Text(files.count == 1 ? L("1 arquivo") : L("%@ arquivos", "\(files.count)")).font(.caption).foregroundStyle(.secondary)
      Spacer()
      Text(verbatim: "+\(added)").font(.caption.monospacedDigit()).foregroundStyle(.green)
      Text(verbatim: "−\(removed)").font(.caption.monospacedDigit()).foregroundStyle(.red)
      Button {
        jump(-1, proxy)
      } label: { Image(systemName: "arrow.up") }.buttonStyle(.borderless).help(L("Alteração anterior")).accessibilityLabel(L("Alteração anterior"))
        .disabled(hunkIDs.isEmpty)
      Button {
        jump(1, proxy)
      } label: { Image(systemName: "arrow.down") }.buttonStyle(.borderless).help(L("Próxima alteração")).accessibilityLabel(L("Próxima alteração"))
        .disabled(hunkIDs.isEmpty)
    }
    .padding(.horizontal, 12).padding(.vertical, 6)
  }
  private func jump(_ step: Int, _ proxy: ScrollViewProxy) {
    let ids = hunkIDs
    guard !ids.isEmpty else { return }
    currentHunk = (currentHunk + step + ids.count) % ids.count
    withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(ids[currentHunk], anchor: .top) }
  }

  private func header(_ file: RenderedFile) -> some View {
    let path = Demo.enabled ? (file.data.path as NSString).lastPathComponent : file.data.path
    let name = (path as NSString).lastPathComponent
    let dir = (path as NSString).deletingLastPathComponent
    let state = stagedState(file.data.path)
    return HStack(spacing: 8) {
      Button {
        if collapsed.contains(file.id) { collapsed.remove(file.id) } else { collapsed.insert(file.id) }
      } label: {
        Image(systemName: collapsed.contains(file.id) ? "chevron.right" : "chevron.down").font(.caption.weight(.semibold)).frame(width: 12)
      }.buttonStyle(.borderless).accessibilityLabel(collapsed.contains(file.id) ? L("Expandir") : L("Recolher"))
      Toggle(
        "",
        isOn: Binding(get: { state != false }, set: { toggleStage(file.data.path, $0) })
      )
      .toggleStyle(.checkbox).labelsHidden()
      .help(state == true ? L("Tirar do stage") : L("Colocar em stage"))
      .overlay { if state == nil { Image(systemName: "minus").font(.system(size: 8, weight: .heavy)).allowsHitTesting(false) } }
      Text(name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(nameColor(file.data))
      if !dir.isEmpty { Text(dir).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
      if let orig = file.data.orig_path { Text("← \(Demo.enabled ? (orig as NSString).lastPathComponent : orig)").font(.caption).foregroundStyle(.secondary) }
      if file.data.new_file { Badge(text: L("novo"), color: .green) }
      if file.data.deleted { Badge(text: L("removido"), color: .red) }
      Spacer(minLength: 12)
      Text(verbatim: "+\(file.data.added)").font(.caption.monospacedDigit()).foregroundStyle(.green)
      Text(verbatim: "−\(file.data.removed)").font(.caption.monospacedDigit()).foregroundStyle(.red)
      if !file.data.deleted && !file.data.binary {
        Button {
          edit(file.data.path)
        } label: { Image(systemName: "pencil") }.controlSize(.small).help(L("Editar aqui (editor do CoreScope)"))
          .accessibilityLabel(L("Editar aqui"))
      }
      if !file.data.deleted {
        Button(L("Abrir")) { open(file.data.path) }.controlSize(.small).help(L("Abrir com %@ (Ajustes › Editor)", CodeEditor.preferredName))
      }
    }
    .padding(.horizontal, 10).padding(.vertical, 6)
    .background(.bar)
    .overlay(alignment: .bottom) { Divider() }
  }
  private func nameColor(_ f: FileDiffData) -> Color {
    f.new_file ? .green : f.deleted ? .red : Color(red: 0.9, green: 0.75, blue: 0.3)
  }

  @ViewBuilder private func fileBody(_ file: RenderedFile) -> some View {
    if file.data.binary {
      note(L("Arquivo binário: sem diff de texto."))
    } else if file.hunks.isEmpty {
      note(file.data.orig_path != nil ? L("Só renomeado, sem mudar o conteúdo.") : L("Sem diferenças de texto (só o modo do arquivo mudou)."))
    } else {
      ForEach(Array(file.hunks.enumerated()), id: \.offset) { index, lines in
        if file.gaps[index] > 0 { gap(file.gaps[index], file) }
        VStack(alignment: .leading, spacing: 0) {
          ForEach(lines) { DiffLineRow(line: $0) }
        }
        .id("\(file.id)#\(index)")
      }
      if file.data.truncated { note(L("Diff cortado: o arquivo tem alterações demais para mostrar.")) }
    }
  }
  private func gap(_ count: Int, _ file: RenderedFile) -> some View {
    Button {
      expand(file.data.path)
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "arrow.up.and.down").font(.caption2)
        Text(count == 1 ? L("1 linha sem mudança") : L("%@ linhas sem mudança", "\(count)")).font(.caption)
      }
      .foregroundStyle(.secondary)
      .padding(.leading, 18).padding(.vertical, 3)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.primary.opacity(0.035))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(L("Mostrar o arquivo inteiro"))
  }
  private func note(_ text: String) -> some View {
    Text(text).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.vertical, 8)
  }
}

private struct DiffScrollX: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct DiffLineRow: View {
  let line: RenderedLine
  var body: some View {
    HStack(spacing: 0) {
      Rectangle().fill(barColor).frame(width: 3)
      Text(line.number.map(String.init) ?? "")
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(line.kind == "+" ? Color.green.opacity(0.85) : .secondary.opacity(0.7))
        .frame(width: 46, alignment: .trailing)
        .padding(.trailing, 12)
      Text(line.text.characters.isEmpty ? AttributedString(" ") : line.text)
        .font(.system(size: 12, design: .monospaced))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.trailing, 24)
      Spacer(minLength: 0)
    }
    .padding(.vertical, 1)
    .background(background)
  }
  private var barColor: Color {
    switch line.mark {
    case .added: .green
    case .removed: .red
    case .modified: Color(red: 0.86, green: 0.7, blue: 0.2)
    case .none: .clear
    }
  }
  private var background: Color {
    switch line.kind {
    case "+": Color.green.opacity(0.14)
    case "-": Color.red.opacity(0.14)
    default: .clear
    }
  }
}
