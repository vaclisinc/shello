import XCTest
@testable import HerdrKit

final class MarkdownBlocksTests: XCTestCase {
    func testAgentStyleReply() {
        let text = """
        ## 結論
        修正已經**裝好**了，用 `herdr agent list` 看。

        1. 對兩個 Claude 各送一句話
           讓 hook 觸發
        2. 在伺服器打：
        - bullet
          - nested

        ```sh
        herdr agent list
        ```
        > note one
        > note two
        ---
        Done.
        """
        XCTAssertEqual(MarkdownParser.blocks(text), [
            .heading(level: 2, text: "結論"),
            .paragraph("修正已經**裝好**了，用 `herdr agent list` 看。"),
            .listItem(marker: "1.", depth: 0, text: "對兩個 Claude 各送一句話\n讓 hook 觸發"),
            .listItem(marker: "2.", depth: 0, text: "在伺服器打："),
            .listItem(marker: "•", depth: 0, text: "bullet"),
            .listItem(marker: "•", depth: 1, text: "nested"),
            .code(language: "sh", text: "herdr agent list"),
            .quote("note one\nnote two"),
            .rule,
            .paragraph("Done."),
        ])
    }

    func testUnclosedFenceKeepsCode() {
        XCTAssertEqual(MarkdownParser.blocks("```\nlet a = 1"), [.code(language: "", text: "let a = 1")])
    }

    func testHashWithoutSpaceIsText() {
        XCTAssertEqual(MarkdownParser.blocks("#hashtag"), [.paragraph("#hashtag")])
    }
}
