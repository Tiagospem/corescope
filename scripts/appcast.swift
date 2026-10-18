// Release helper behind scripts/appcast.sh, compiled with native/UpdateLogic.swift.
//   appcast item VERSION BUILD URL LENGTH SIGNATURE NOTES_FILE   prints the appcast
//   appcast public-key                                           public key of the private key on stdin
//   appcast keygen                                               a throwaway key pair (dry runs, tests)
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(1)
}
@main struct AppcastTool {
  static func main() {
    let args = Array(CommandLine.arguments.dropFirst())
    switch args.first {
    case "item" where args.count == 7:
      guard let length = Int(args[4]) else { fail("LENGTH must be a number") }
      guard let notes = try? String(contentsOfFile: args[6], encoding: .utf8) else { fail("cannot read \(args[6])") }
      let item = AppcastItem(
        build: args[2], version: args[1], url: args[3], length: length, edSignature: args[5],
        notes: notes.trimmingCharacters(in: .whitespacesAndNewlines), date: Date())
      let xml = Appcast.render([item])
      // Never publish what Sparkle could not read back.
      guard let back = Appcast.parse(Data(xml.utf8))?.first,
        back.build == item.build, back.version == item.version, back.url == item.url,
        back.length == item.length, back.edSignature == item.edSignature, back.notes == item.notes
      else { fail("the rendered appcast does not parse back") }
      print(xml, terminator: "")
    case "public-key":
      let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
      guard let seed = Data(base64Encoded: input.trimmingCharacters(in: .whitespacesAndNewlines)),
        let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed.prefix(32))
      else { fail("stdin is not a base64 EdDSA private key (generate_keys -x)") }
      print(key.publicKey.rawRepresentation.base64EncodedString())
    case "keygen":
      let key = Curve25519.Signing.PrivateKey()
      print("private: \(key.rawRepresentation.base64EncodedString())")
      print("public: \(key.publicKey.rawRepresentation.base64EncodedString())")
    default:
      fail("usage: appcast item VERSION BUILD URL LENGTH SIGNATURE NOTES_FILE | public-key | keygen")
    }
  }
}
