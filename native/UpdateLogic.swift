import Foundation

/// Update logic without Sparkle or UI, shared by the app, the appcast generator
/// (scripts/appcast.sh) and the native tests.
enum UpdateLogic {
  /// Orders marketing versions ("0.5.1", "v0.10.0", "1.0.0-beta.2"): numeric parts compared as
  /// numbers, missing parts as 0, and a pre-release before its release.
  static func compare(_ a: String, _ b: String) -> ComparisonResult {
    func parts(_ v: String) -> ([Int], String?) {
      var s = v.trimmingCharacters(in: .whitespaces)
      if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
      let split = s.split(separator: "-", maxSplits: 1).map(String.init)
      let core = (split.first ?? "").split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
      return (core, split.count > 1 ? split[1] : nil)
    }
    let (x, xPre) = parts(a), (y, yPre) = parts(b)
    for i in 0..<max(x.count, y.count) {
      let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
      if l != r { return l < r ? .orderedAscending : .orderedDescending }
    }
    switch (xPre, yPre) {
    case (nil, nil): return .orderedSame
    case (nil, _): return .orderedDescending
    case (_, nil): return .orderedAscending
    case let (l?, r?): return l.compare(r, options: .numeric)
    }
  }
  static func isNewer(_ candidate: String, than current: String) -> Bool {
    compare(candidate, current) == .orderedDescending
  }
}

/// A CHANGELOG section (Keep a Changelog markdown) as blocks the update card can draw:
/// `### Added` headings, `- ` bullets (indented continuation lines joined) and paragraphs.
enum NoteBlock: Equatable {
  case heading(String)
  case bullet(String)
  case text(String)

  static func parse(_ markdown: String) -> [NoteBlock] {
    var out: [NoteBlock] = []
    for raw in markdown.components(separatedBy: .newlines) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.isEmpty { continue }
      if line.hasPrefix("#") {
        out.append(.heading(String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
      } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
        out.append(.bullet(String(line.dropFirst(2))))
      } else if raw.hasPrefix(" "), case .bullet(let text)? = out.last {
        out[out.count - 1] = .bullet(text + " " + line)
      } else if case .text(let text)? = out.last {
        out[out.count - 1] = .text(text + " " + line)
      } else {
        out.append(.text(line))
      }
    }
    return out
  }
}

/// One release in the Sparkle appcast the release workflow publishes as a release asset.
struct AppcastItem: Equatable {
  /// CFBundleVersion of the new build (what Sparkle compares) and the marketing version.
  var build: String
  var version: String
  var url: String
  var length: Int
  var edSignature: String
  var notes: String
  var date: Date
  var minimumSystemVersion = "14.0"
}

enum Appcast {
  /// RSS with one item per release; the notes go in a markdown description (CDATA).
  static func render(_ items: [AppcastItem], title: String = "CoreScope") -> String {
    let dateFormat = DateFormatter()
    dateFormat.locale = Locale(identifier: "en_US_POSIX")
    dateFormat.timeZone = TimeZone(identifier: "UTC")
    dateFormat.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
    var lines = [
      #"<?xml version="1.0" encoding="utf-8"?>"#,
      #"<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">"#,
      "  <channel>",
      "    <title>\(escape(title))</title>",
    ]
    for item in items {
      let notes = item.notes.replacingOccurrences(of: "]]>", with: "]]]]><![CDATA[>")
      lines += [
        "    <item>",
        "      <title>\(escape("\(title) \(item.version)"))</title>",
        "      <pubDate>\(dateFormat.string(from: item.date))</pubDate>",
        "      <sparkle:version>\(escape(item.build))</sparkle:version>",
        "      <sparkle:shortVersionString>\(escape(item.version))</sparkle:shortVersionString>",
        "      <sparkle:minimumSystemVersion>\(escape(item.minimumSystemVersion))</sparkle:minimumSystemVersion>",
        #"      <description sparkle:format="markdown"><![CDATA["# + notes + "]]></description>",
        #"      <enclosure url="\#(escape(item.url))" length="\#(item.length)" type="application/octet-stream" sparkle:edSignature="\#(escape(item.edSignature))"/>"#,
        "    </item>",
      ]
    }
    lines += ["  </channel>", "</rss>", ""]
    return lines.joined(separator: "\n")
  }

  /// Reads the items back (what Sparkle needs from each); nil when the XML is malformed.
  static func parse(_ data: Data) -> [AppcastItem]? {
    let reader = Reader()
    let parser = XMLParser(data: data)
    parser.shouldProcessNamespaces = false
    parser.delegate = reader
    return parser.parse() ? reader.items : nil
  }

  private static func escape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
  }

  private final class Reader: NSObject, XMLParserDelegate {
    var items: [AppcastItem] = []
    private var current: AppcastItem?
    private var text = ""
    private let dates: DateFormatter = {
      let f = DateFormatter()
      f.locale = Locale(identifier: "en_US_POSIX")
      f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
      return f
    }()
    func parser(
      _ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
      attributes: [String: String] = [:]
    ) {
      text = ""
      if name == "item" {
        current = AppcastItem(build: "", version: "", url: "", length: 0, edSignature: "", notes: "", date: .distantPast)
      } else if name == "enclosure" {
        current?.url = attributes["url"] ?? ""
        current?.length = Int(attributes["length"] ?? "") ?? 0
        current?.edSignature = attributes["sparkle:edSignature"] ?? ""
      }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, foundCDATA block: Data) { text += String(decoding: block, as: UTF8.self) }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
      let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
      switch name {
      case "sparkle:version": current?.build = value
      case "sparkle:shortVersionString": current?.version = value
      case "sparkle:minimumSystemVersion": current?.minimumSystemVersion = value
      case "description": current?.notes = value
      case "pubDate": current?.date = dates.date(from: value) ?? .distantPast
      case "item": if let current { items.append(current) }
        current = nil
      default: break
      }
      text = ""
    }
  }
}
