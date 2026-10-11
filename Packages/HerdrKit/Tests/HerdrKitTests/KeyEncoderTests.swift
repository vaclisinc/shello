import XCTest
@testable import HerdrKit

final class KeyEncoderTests: XCTestCase {
    private func kitty(_ key: TerminalKey, _ modifiers: KeyModifiers = []) -> String {
        String(decoding: KeyEncoder.encode(key, modifiers: modifiers, kitty: true), as: UTF8.self)
    }

    private func legacy(_ key: TerminalKey, _ modifiers: KeyModifiers = [], applicationCursor: Bool = false) -> String {
        String(decoding: KeyEncoder.encode(key, modifiers: modifiers, kitty: false, applicationCursor: applicationCursor), as: UTF8.self)
    }

    func testKittyShiftCombos() {
        XCTAssertEqual(kitty(.enter, .shift), "\u{1b}[13;2u")
        XCTAssertEqual(kitty(.tab, .shift), "\u{1b}[9;2u")
        XCTAssertEqual(kitty(.up, .shift), "\u{1b}[1;2A")
        XCTAssertEqual(kitty(.pageUp, .shift), "\u{1b}[5;2~")
        XCTAssertEqual(kitty(.char("a"), .shift), "A")
    }

    func testKittyPlainAndCtrl() {
        XCTAssertEqual(kitty(.enter), "\r")
        XCTAssertEqual(kitty(.tab), "\t")
        XCTAssertEqual(kitty(.escape), "\u{1b}[27u")
        XCTAssertEqual(kitty(.char("c"), .ctrl), "\u{1b}[99;5u")
        XCTAssertEqual(kitty(.char("C"), [.ctrl, .shift]), "\u{1b}[99;6u")
        XCTAssertEqual(kitty(.enter, [.ctrl, .alt]), "\u{1b}[13;7u")
    }

    func testLegacyShiftCombos() {
        XCTAssertEqual(legacy(.tab, .shift), "\u{1b}[Z")
        XCTAssertEqual(legacy(.enter, .shift), "\u{1b}\r")
        XCTAssertEqual(legacy(.left, .ctrl), "\u{1b}[1;5D")
        XCTAssertEqual(legacy(.char("x"), .shift), "X")
    }

    func testLegacyControlAndAlt() {
        XCTAssertEqual(KeyEncoder.encode(.char("c"), modifiers: .ctrl, kitty: false), [0x03])
        XCTAssertEqual(KeyEncoder.encode(.char("c"), modifiers: [.ctrl, .alt], kitty: false), [0x1b, 0x03])
        XCTAssertEqual(KeyEncoder.encode(.char("b"), modifiers: .alt, kitty: false), [0x1b, 0x62])
        XCTAssertEqual(KeyEncoder.encode(.escape, kitty: false), [0x1b])
        XCTAssertEqual(KeyEncoder.encode(.backspace, kitty: false), [0x7f])
    }

    func testApplicationCursor() {
        XCTAssertEqual(legacy(.up, applicationCursor: true), "\u{1b}OA")
        XCTAssertEqual(legacy(.up), "\u{1b}[A")
        XCTAssertEqual(legacy(.up, .shift, applicationCursor: true), "\u{1b}[1;2A")
    }
}
