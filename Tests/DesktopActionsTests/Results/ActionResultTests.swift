import DesktopActions
import Foundation
import XCTest

final class ActionResultTests: XCTestCase {
  func testFactoriesUseSharedDefaultsAndNativeCategories() throws {
    let errors: [(ActionError, ActionErrorCode, String)] = [
      (.invalidInput(" \n"), .invalidInput, "Invalid input"),
      (.permissionDenied(.accessibility), .permissionDenied, "Permission denied: accessibility"),
      (.notFound(""), .notFound, "Not found"),
      (.openFailed(""), .openFailed, "Open failed"),
      (.appleScriptFailed(""), .appleScriptFailed, "AppleScript failed"),
      (.screenCaptureFailed(""), .screenCaptureFailed, "Screen capture failed"),
      (.internalError(""), .internalError, "Internal error"),
      (.unsupportedAction(), .unsupportedAction, "Unsupported action"),
      (.accessDenied(nativeCode: 5), .accessDenied, "Native access denied"),
      (.nativeFailed(nativeCode: 87), .nativeFailed, "Native operation failed"),
      (.timedOut(), .timedOut, "ActionRequest timed out"),
      (.busy(), .busy, "Execution capacity is full"),
    ]
    XCTAssertEqual(Set(errors.map { $0.1 }), Set(ActionErrorCode.allCases))
    for (error, code, message) in errors {
      XCTAssertEqual(error.code, code)
      XCTAssertEqual(error.diagnosticMessage, message)
      XCTAssertEqual(error.localizedDescription, message)
      XCTAssertEqual(try ActionResultCodec.decodeError(ActionResultCodec.encode(error)), error)
      XCTAssertEqual(
        try JSONDecoder().decode(ActionError.self, from: JSONEncoder().encode(error)), error)
    }
    XCTAssertEqual(errors[8].0.nativeCode, 5)
    XCTAssertEqual(errors[9].0.nativeCode, 87)
    XCTAssertEqual(ActionError.notFound("  missing \n").diagnosticMessage, "missing")
  }

  func testAppleScriptNumbersArePreservedWithoutDuplicatingDiagnosticSuffix() throws {
    let denial = ActionError.automationPermissionDenied(appleScriptErrorNumber: -1743)
    XCTAssertEqual(denial.permission, .automation)
    XCTAssertEqual(denial.appleScriptErrorNumber, -1743)
    XCTAssertEqual(
      denial.diagnosticMessage, "Permission denied: automation (AppleScript error number -1743)")
    let script = ActionError.appleScriptFailed("failure", appleScriptErrorNumber: 42)
    XCTAssertEqual(script.diagnosticMessage, "failure (AppleScript error number 42)")
    XCTAssertEqual(
      ActionError.appleScriptFailed(script.diagnosticMessage, appleScriptErrorNumber: 42), script)
    XCTAssertEqual(try ActionResultCodec.decodeError(ActionResultCodec.encode(denial)), denial)
    XCTAssertNil(ActionError.permissionDenied(.automation).appleScriptErrorNumber)
  }

  func testByteCodecMapsMalformedErrorsToInvalidData() {
    let raw = #"{"code":"open-failed","diagnosticMessage":" "}"#
    assertInvalid { _ = try ActionResultCodec.decodeError(Data(raw.utf8)) }
  }

  func testOriginalResultWireRejectsInvalidUTF8WithoutReplacingDiagnostics() throws {
    let diagnostic = "日本語🙂\u{FFFD}"
    let error = ActionError.invalidInput(diagnostic)
    let result = ActionResult.failure(error)
    let attempt = ActionAttempt(requiredPermissions: [], isFallback: false, result: result)
    let report = ActionExecutionReport(attempts: [attempt])

    let errorWire = try ActionResultCodec.encode(error)
    let resultWire = try ActionResultCodec.encode(result)
    let attemptWire = try ActionResultCodec.encode(attempt)
    let reportWire = try ActionResultCodec.encode(report)
    XCTAssertEqual(try ActionResultCodec.decodeError(errorWire), error)
    XCTAssertEqual(try ActionResultCodec.decodeResult(resultWire), result)
    XCTAssertEqual(try ActionResultCodec.decodeAttempt(attemptWire), attempt)
    XCTAssertEqual(try ActionResultCodec.decodeExecutionReport(reportWire), report)

    for (wire, validate) in [
      (errorWire, { data in _ = try ActionResultCodec.decodeError(data) }),
      (resultWire, { data in _ = try ActionResultCodec.decodeResult(data) }),
      (attemptWire, { data in _ = try ActionResultCodec.decodeAttempt(data) }),
      (reportWire, { data in _ = try ActionResultCodec.decodeExecutionReport(data) }),
    ] as [(Data, (Data) throws -> Void)] {
      var invalid = wire
      invalid[try XCTUnwrap(invalid.range(of: Data(diagnostic.utf8))).lowerBound] = 0xff
      assertInvalid { try validate(invalid) }
    }
  }

  func testResultProjectionsUseCanonicalAssociatedPayloads() throws {
    for value: ActionResult in [
      .success, .skipped(.noFocusedWindow), .skipped(.noFrontmostApplication),
      .failure(.nativeFailed("failed", nativeCode: 87)),
    ] {
      let data = try ActionResultCodec.encode(value)
      XCTAssertEqual(try ActionResultCodec.decodeResult(data), value)
      XCTAssertEqual(
        try JSONDecoder().decode(ActionResult.self, from: JSONEncoder().encode(value)), value)
      let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
      switch value {
      case .success: XCTAssertEqual(Set(keys), ["status"])
      case .skipped: XCTAssertEqual(Set(keys), ["status", "skipReason"])
      case .failure: XCTAssertEqual(Set(keys), ["status", "error"])
      }
    }
    let duplicate =
      #"{"status":"failure","error":{"code":"native-failed","diagnosticMessage":"failed","nativeCode":5,"nativeCode":87}}"#
    assertInvalid { _ = try ActionResultCodec.decodeResult(Data(duplicate.utf8)) }
  }

  func testAttemptDurationAndPermissionProjectionUsesSharedLimits() throws {
    for duration: Duration? in [
      nil, .zero, .milliseconds(250), .nanoseconds(1), .seconds(1_000_000),
    ] {
      let attempt = ActionAttempt(
        requiredPermissions: [.screenRecording, .automation, .accessibility],
        isFallback: true, result: .success, duration: duration)
      let data = try ActionResultCodec.encode(attempt)
      let decoded = try ActionResultCodec.decodeAttempt(data)
      XCTAssertEqual(decoded, attempt)
      XCTAssertEqual(decoded.duration, duration)
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
      XCTAssertEqual(
        object["requiredPermissions"] as? [String],
        ["accessibility", "automation", "screen-recording"])
      XCTAssertEqual(object["durationSeconds"] == nil, duration == nil)
    }
    for duration: Duration in [
      .seconds(-1), .init(secondsComponent: Int64.max, attosecondsComponent: 0),
    ] {
      let attempt = ActionAttempt(
        requiredPermissions: [], isFallback: false, result: .success, duration: duration)
      assertInvalid { _ = try ActionResultCodec.encode(attempt) }
      XCTAssertThrowsError(try JSONEncoder().encode(attempt)) { error in
        guard case EncodingError.invalidValue(_, let context) = error else {
          return XCTFail("\(error)")
        }
        XCTAssertNotNil(context.underlyingError as? ActionCodecError)
      }
    }
    let duplicate =
      #"{"requiredPermissions":["automation","automation"],"isFallback":false,"result":{"status":"success"}}"#
    assertInvalid { _ = try ActionResultCodec.decodeAttempt(Data(duplicate.utf8)) }
    // The largest representable f64 below 2^63 must remain safe at the Duration boundary.
    let upper =
      #"{"requiredPermissions":[],"isFallback":false,"result":{"status":"success"},"durationSeconds":9223372036854774784}"#
    let attempt = try ActionResultCodec.decodeAttempt(Data(upper.utf8))
    XCTAssertNotNil(attempt.duration)
    XCTAssertEqual(try ActionResultCodec.decodeAttempt(ActionResultCodec.encode(attempt)), attempt)
  }

  func testWireDurationBelowOneAttosecondSurvivesSwiftRoundTrips() throws {
    struct WireAttempt: Decodable { let durationSeconds: Double }
    struct WireReport: Decodable { let attempts: [WireAttempt] }

    let raw =
      #"{"requiredPermissions":[],"isFallback":false,"result":{"status":"success"},"durationSeconds":1e-19}"#
    let expectedBits = Double(1e-19).bitPattern
    let attempt = try ActionResultCodec.decodeAttempt(Data(raw.utf8))
    let zero = try ActionResultCodec.decodeAttempt(
      Data(raw.replacingOccurrences(of: "1e-19", with: "0").utf8))

    XCTAssertEqual(attempt.duration, Duration.zero)
    XCTAssertEqual(attempt.duration, zero.duration)
    XCTAssertEqual(attempt.durationSeconds?.bitPattern, expectedBits)
    XCTAssertNotEqual(attempt, zero)
    XCTAssertEqual(Set([attempt, zero]).count, 2)
    let encoded = try ActionResultCodec.encode(attempt)
    XCTAssertEqual(
      try JSONDecoder().decode(WireAttempt.self, from: encoded).durationSeconds.bitPattern,
      expectedBits)

    let reportJSON = Data(#"{"finalResult":{"status":"success"},"attempts":[\#(raw)]}"#.utf8)
    let report = try ActionResultCodec.decodeExecutionReport(reportJSON)
    let genericReport = try JSONDecoder().decode(ActionExecutionReport.self, from: reportJSON)
    XCTAssertEqual(report.attempts, [attempt])
    XCTAssertEqual(genericReport, report)
    for data in [try ActionResultCodec.encode(report), try JSONEncoder().encode(genericReport)] {
      let wire = try JSONDecoder().decode(WireReport.self, from: data)
      XCTAssertEqual(wire.attempts.map(\.durationSeconds.bitPattern), [expectedBits])
    }
  }

  func testWireResultEqualityUsesExactDiagnosticSpellingAndNumericDuration() throws {
    let composed = ActionError.invalidInput("caf\u{E9}")
    let decomposed = ActionError.invalidInput("cafe\u{301}")
    let composedReport = ActionExecutionReport(result: .failure(composed))
    let decomposedReport = ActionExecutionReport(result: .failure(decomposed))
    XCTAssertEqual(Set([composed, decomposed]).count, 2)
    XCTAssertEqual(Set([composedReport, decomposedReport]).count, 2)
    let decoded = try ActionResultCodec.decodeExecutionReport(
      ActionResultCodec.encode(composedReport))
    XCTAssertEqual(Set([composedReport, decoded]).count, 1)

    let zeroWire =
      #"{"requiredPermissions":[],"isFallback":false,"result":{"status":"success"},"durationSeconds":0.0}"#
    let zero = try ActionResultCodec.decodeAttempt(Data(zeroWire.utf8))
    let negativeZero = try ActionResultCodec.decodeAttempt(
      Data(zeroWire.replacingOccurrences(of: "0.0", with: "-0.0").utf8))
    XCTAssertEqual(negativeZero.durationSeconds?.bitPattern, Double(-0.0).bitPattern)
    let tiny = try ActionResultCodec.decodeAttempt(
      Data(zeroWire.replacingOccurrences(of: "0.0", with: "1e-19").utf8))
    let unmeasured = ActionAttempt(requiredPermissions: [], isFallback: false, result: .success)
    XCTAssertEqual(Set([zero, negativeZero, tiny, unmeasured]).count, 3)
    XCTAssertNotEqual(
      ActionExecutionReport(attempts: [zero, tiny, unmeasured]),
      ActionExecutionReport(attempts: [tiny, zero, unmeasured]))
  }

  func testOutcomeFactoryAndCodecPreserveHistoryAndRejectContradictions() throws {
    let empty = ActionExecutionReport(attempts: [])
    XCTAssertEqual(empty.attempts.count, 1)
    XCTAssertEqual(
      empty.finalResult, .failure(.internalError("No execution attempts were recorded")))
    XCTAssertNil(empty.successfulAttempt)
    let failed = ActionAttempt(
      requiredPermissions: [.automation], isFallback: false,
      result: .failure(.automationPermissionDenied(appleScriptErrorNumber: -1743)))
    let success = ActionAttempt(
      requiredPermissions: [.accessibility], isFallback: true,
      result: .success, duration: .milliseconds(250))
    let outcome = ActionExecutionReport(attempts: [failed, success])
    XCTAssertEqual(outcome.finalResult, .success)
    XCTAssertEqual(outcome.successfulAttempt, success)
    XCTAssertTrue(outcome.didAttemptFallback)
    XCTAssertEqual(
      try ActionResultCodec.decodeExecutionReport(ActionResultCodec.encode(outcome)), outcome)
    XCTAssertEqual(
      try JSONDecoder().decode(ActionExecutionReport.self, from: JSONEncoder().encode(outcome)),
      outcome)
    let host = ActionExecutionReport(result: .skipped(.noFocusedWindow))
    XCTAssertEqual(host.attempts[0].requiredPermissions, [])
    XCTAssertNil(host.attempts[0].duration)
    XCTAssertFalse(host.didAttemptFallback)
    let contradictory =
      #"{"finalResult":{"status":"success"},"attempts":[{"requiredPermissions":[],"isFallback":false,"result":{"status":"skipped","skipReason":"no-focused-window"}}]}"#
    assertInvalid { _ = try ActionResultCodec.decodeExecutionReport(Data(contradictory.utf8)) }
  }

  func testNestedCodablePreservesCallerContextAndNativeCause() {
    struct Envelope: Decodable { let report: ActionExecutionReport }
    let raw = #"{"report":{"finalResult":{"status":"success"},"attempts":[]}}"#
    XCTAssertThrowsError(try JSONDecoder().decode(Envelope.self, from: Data(raw.utf8))) { error in
      guard case DecodingError.dataCorrupted(let context) = error else {
        return XCTFail("\(error)")
      }
      XCTAssertEqual(context.codingPath.map(\.stringValue), ["report"])
      XCTAssertNotNil(context.underlyingError as? ActionCodecError)
    }
  }

  private func assertInvalid(
    _ operation: () throws -> Void, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertThrowsError(try operation(), file: file, line: line) { error in
      guard case ActionCodecError.invalidData = error else {
        return XCTFail("\(error)", file: file, line: line)
      }
    }
  }
}
