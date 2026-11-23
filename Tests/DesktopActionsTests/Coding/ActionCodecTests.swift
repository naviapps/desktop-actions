import DesktopActions
import XCTest

final class ActionCodecTests: XCTestCase {
  func testCurrentVersionMatchesEncodedEnvelopeVersion() throws {
    let data = try ActionCodec.encode(.copy)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

    XCTAssertEqual(ActionCodec.currentVersion, 1)
    XCTAssertEqual(object?["version"] as? Int, ActionCodec.currentVersion)
  }

  func testEncodeUsesVersionedEnvelopeShape() throws {
    let data = try ActionCodec.encode(.openURL("https://example.com"))
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let action = object?["action"] as? [String: Any]

    XCTAssertEqual(object?["version"] as? Int, ActionCodec.currentVersion)
    XCTAssertEqual(action?["kind"] as? String, "action.workspace.open-url")
    XCTAssertEqual(action?["input"] as? String, "https://example.com")
  }

  func testEncodeDecodeRoundTrip() throws {
    let action = ActionRequest.keyboardShortcut("cmd+shift+k")
    let data = try ActionCodec.encode(action)
    let decoded = try ActionCodec.decode(data)
    XCTAssertEqual(decoded, action)
  }

  func testOriginalWireCodecsRejectInvalidUTF8WithoutReplacingText() throws {
    let text = "日本語🙂\u{FFFD}"
    let input = #"{"shape":"string","value":"\#(text)"}"#
    let request = #"{"kind":"action.workspace.open-folder","input":"\#(text)"}"#
    let envelope = #"{"version":1,"action":\#(request)}"#
    XCTAssertEqual(try ActionCodec.decodeInput(Data(input.utf8)), .string(text))
    XCTAssertEqual(try ActionCodec.decodeRequest(Data(request.utf8)), .openFolder(text))
    XCTAssertEqual(try ActionCodec.decode(Data(envelope.utf8)), .openFolder(text))

    for (wire, validate) in [
      (input, { data in _ = try ActionCodec.decodeInput(data) }),
      (request, { data in _ = try ActionCodec.decodeRequest(data) }),
      (envelope, { data in _ = try ActionCodec.decode(data) }),
    ] as [(String, (Data) throws -> Void)] {
      let invalid = Data(wire.replacingOccurrences(of: text, with: "@").utf8).map {
        $0 == 0x40 ? UInt8(0xff) : $0
      }
      XCTAssertThrowsError(try validate(Data(invalid))) { error in
        guard case ActionCodecError.invalidData = error else { return XCTFail("\(error)") }
      }
    }
    for (wire, validate) in [
      (
        #"{"shape":"string","value":"a","value":"b"}"#,
        { data in
          _ = try ActionCodec.decodeInput(data)
        }
      ),
      (
        #"{"kind":"action.workspace.open-folder","input":"a","input":"b"}"#,
        { data in
          _ = try ActionCodec.decodeRequest(data)
        }
      ),
    ] as [(String, (Data) throws -> Void)] {
      XCTAssertThrowsError(try validate(Data(wire.utf8))) { error in
        guard case ActionCodecError.invalidData = error else { return XCTFail("\(error)") }
      }
    }
  }

  func testSelectAllAndFindAreDistinctFromExplicitPhysicalShortcuts() throws {
    let cases: [(request: ActionRequest, identifier: String, shortcut: String)] = [
      (.selectAll, "action.editing.select-all", "cmd+a"),
      (.findInApp, "action.editing.find-in-app", "cmd+f"),
    ]
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    for (request, identifier, shortcut) in cases {
      let logical = Data(#"{"action":{"kind":"\#(identifier)"},"version":1}"#.utf8)
      let physical = Data(
        #"{"action":{"input":"\#(shortcut)","kind":"action.keyboard.shortcut"},"version":1}"#.utf8)
      XCTAssertEqual(try ActionCodec.decode(logical), request)
      XCTAssertEqual(try ActionCodec.encode(request, encoder: encoder), logical)
      XCTAssertEqual(try ActionCodec.decode(physical), .keyboardShortcut(shortcut))
      XCTAssertEqual(
        try ActionCodec.encode(.keyboardShortcut(shortcut), encoder: encoder), physical)
    }
  }

  func testDecodeRejectsUnsupportedVersionWithoutReadingActionPayload() {
    let data = Data(
      """
      {"version":999}
      """.utf8
    )

    XCTAssertThrowsError(try ActionCodec.decode(data)) { error in
      XCTAssertEqual(error as? ActionCodecError, .unsupportedVersion(999))
    }
  }

  func testDecodeRejectsUnknownEnvelopeFields() {
    let data = Data(
      """
      {
        "version": 1,
        "action": {
          "kind": "action.editing.copy"
        },
        "metadata": {}
      }
      """.utf8
    )

    XCTAssertThrowsError(try ActionCodec.decode(data))
  }

  func testActionCodecErrorDescribesUnsupportedVersion() {
    XCTAssertEqual(
      ActionCodecError.unsupportedVersion(999).localizedDescription,
      "Unsupported action envelope version: 999."
    )
  }

  func testActionCodecErrorIsHashable() {
    XCTAssertEqual(
      Set([
        ActionCodecError.unsupportedVersion(999),
        ActionCodecError.unsupportedVersion(999),
      ]).count,
      1
    )
  }
}
