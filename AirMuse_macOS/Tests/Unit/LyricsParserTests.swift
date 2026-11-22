// Tests/Unit/LyricsParserTests.swift
// AirMuse macOS – Unit tests for LRC lyrics parsing (no Lyrics module dependency; pure Domain)

import Testing
import Foundation
@testable import Domain

// MARK: - LRC Timestamp parser (inline, testing Domain-level logic)

private func parseLRCTimestamp(_ s: String) -> TimeInterval? {
    // Expected format: mm:ss.xx  or  mm:ss.xxx
    let pattern = #"^\[(\d{1,2}):(\d{2})\.(\d{2,3})\]$"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else {
        return nil
    }
    func group(_ i: Int) -> String {
        let r = match.range(at: i)
        return String(s[Range(r, in: s)!])
    }
    guard let min = Double(group(1)),
          let sec = Double(group(2)),
          let frac = Double(group(3)) else { return nil }
    let fracDivisor: Double = group(3).count == 3 ? 1000.0 : 100.0
    return min * 60.0 + sec + frac / fracDivisor
}

// MARK: - Tests

struct LyricsParserTests {

    @Test func timestampFullSeconds() {
        let t = parseLRCTimestamp("[01:23.45]")
        #expect(t != nil)
        #expect(abs(t! - (60 + 23 + 0.45)) < 0.001)
    }

    @Test func timestampMilliseconds() {
        let t = parseLRCTimestamp("[00:05.123]")
        #expect(t != nil)
        #expect(abs(t! - 5.123) < 0.001)
    }

    @Test func timestampInvalidFormat() {
        #expect(parseLRCTimestamp("[abc]") == nil)
        #expect(parseLRCTimestamp("01:23.45") == nil)
        #expect(parseLRCTimestamp("[99:99]") == nil)
    }

    @Test func timestampZero() {
        let t = parseLRCTimestamp("[00:00.00]")
        #expect(t == 0.0)
    }

    @Test func lyricsDocumentActiveLineSelection() {
        let lines = [
            LyricsLine(timeMs: 0,    text: "intro"),
            LyricsLine(timeMs: 5000, text: "verse 1"),
            LyricsLine(timeMs: 10_000, text: "verse 2"),
            LyricsLine(timeMs: 20_000, text: "chorus"),
        ]
        let doc = LyricsDocument(trackKey: "test", lines: lines)

        // At 0 ms → first line
        #expect(doc.activeLine(at: 0) == 0)
        // At 7000 ms → line index 1 (verse 1)
        #expect(doc.activeLine(at: 7_000) == 1)
        // At 15000 ms → line index 2 (verse 2)
        #expect(doc.activeLine(at: 15_000) == 2)
        // At 25000 ms → last line (chorus)
        #expect(doc.activeLine(at: 25_000) == 3)
        // Before any line
        #expect(doc.activeLine(at: -1) == nil)
    }

    @Test func lyricsDocumentEmptyReturnsNil() {
        let doc = LyricsDocument(trackKey: "empty", lines: [])
        #expect(doc.activeLine(at: 5_000) == nil)
    }
}

