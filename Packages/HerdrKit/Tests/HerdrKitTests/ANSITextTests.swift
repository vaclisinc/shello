import XCTest
@testable import HerdrKit

final class ANSITextTests: XCTestCase {
    func testTrueColorAndReset() {
        let spans = ANSIParser.parse("\u{1B}[0m\u{1B}[38;2;0;153;255mOpus\u{1B}[0m plain")
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].text, "Opus")
        XCTAssertEqual(spans[0].style.foreground, .rgb(0, 153, 255))
        XCTAssertEqual(spans[1].text, " plain")
        XCTAssertNil(spans[1].style.foreground)
    }

    func testPaletteBoldDimAndBackground() {
        let spans = ANSIParser.parse("\u{1B}[1;31mA\u{1B}[22;2;38;5;208;44mB")
        XCTAssertEqual(spans[0].style.foreground, .indexed(1))
        XCTAssertTrue(spans[0].style.bold)
        XCTAssertEqual(spans[1].style.foreground, .indexed(208))
        XCTAssertEqual(spans[1].style.background, .indexed(4))
        XCTAssertFalse(spans[1].style.bold)
        XCTAssertTrue(spans[1].style.dim)
    }

    func testDropsOtherSequencesAndCarriageReturns() {
        let spans = ANSIParser.parse("a\u{1B}[2Kb\u{1B}]0;title\u{07}c\r\nd")
        XCTAssertEqual(spans.map(\.text).joined(), "abc\nd")
    }

    func testLinesTrimInvisibleTrailingBlanks() {
        let lines = ANSIParser.lines("\u{1B}[32mok\u{1B}[0m     \r\n\u{1B}[41m  \u{1B}[0m   ")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].map(\.text), ["ok"])
        // Spaces with a background color are visible and stay.
        XCTAssertEqual(lines[1].map(\.text), ["  "])
    }

    func testDisplayColumnsCountsWideCharacters() {
        XCTAssertEqual(ANSIParser.displayColumns("abc"), 3)
        XCTAssertEqual(ANSIParser.displayColumns("和弦ab"), 6)
    }
}
