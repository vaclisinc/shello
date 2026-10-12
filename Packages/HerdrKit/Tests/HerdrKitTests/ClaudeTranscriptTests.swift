import XCTest
@testable import HerdrKit

final class ClaudeTranscriptTests: XCTestCase {
    private let lines = [
        // Partial first line from `tail -c`: ignored.
        #"t":"half a line"}"#,
        #"{"type":"user","uuid":"u1","message":{"role":"user","content":"Fix the build<system-reminder>noise</system-reminder>"}}"#,
        #"{"type":"user","uuid":"m1","isMeta":true,"message":{"role":"user","content":"meta"}}"#,
        #"{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"Looking."}]}}"#,
        #"{"type":"assistant","uuid":"a2","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"npm test","description":"Run tests"}}]}}"#,
        #"{"type":"user","uuid":"r1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"2 passing","is_error":false}]}}"#,
        #"{"type":"assistant","uuid":"a3","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Edit","input":{"file_path":"/src/app.ts","old_string":"a"}}]}}"#,
        #"{"type":"user","uuid":"u2","message":{"role":"user","content":[{"type":"image","source":{"type":"base64","data":"AAAA"}},{"type":"text","text":"this?"}]}}"#,
        #"{"type":"user","uuid":"c1","message":{"role":"user","content":"<command-name>/compact</command-name>\n<command-args></command-args>"}}"#,
        #"{"type":"user","uuid":"c2","message":{"role":"user","content":"<local-command-stdout>done</local-command-stdout>"}}"#,
        #"{"type":"mode","mode":"auto"}"#,
    ]

    func testBuildsChatItems() {
        var transcript = ClaudeTranscript()
        transcript.ingest(lines.joined(separator: "\n"))
        let items = transcript.items
        XCTAssertEqual(items.count, 6)
        XCTAssertEqual(items[0], .user(id: "u1", text: "Fix the build", images: []))
        XCTAssertEqual(items[1], .assistant(id: "a1-1", text: "Looking."))
        guard case .tool(let bash) = items[2], case .tool(let edit) = items[3] else { return XCTFail("\(items)") }
        XCTAssertEqual(bash.summary, "npm test")
        XCTAssertEqual(bash.result, "2 passing")
        XCTAssertEqual(edit.summary, "/src/app.ts")
        XCTAssertTrue(edit.isPending, "no result yet: waiting for approval or still running")
        XCTAssertEqual(items[4], .user(id: "u2", text: "this?", images: [Data([0, 0, 0])]))
        XCTAssertEqual(items[5], .user(id: "c1", text: "/compact", images: []))
    }

    func testCompactionSummaryIsNotAUserMessage() {
        var transcript = ClaudeTranscript()
        transcript.ingest(#"{"type":"system","subtype":"compact_boundary","content":"Conversation compacted"}"#)
        transcript.ingest(#"{"type":"user","uuid":"s1","isCompactSummary":true,"message":{"role":"user","content":"Summary: did things"}}"#)
        transcript.ingest(#"{"type":"user","uuid":"s2","message":{"role":"user","content":[{"type":"text","text":"This session is being continued from a previous conversation that ran out of context."}]}}"#)
        XCTAssertEqual(transcript.items, [
            .compacted(id: "s1", summary: "Summary: did things"),
            .compacted(id: "s2", summary: "This session is being continued from a previous conversation that ran out of context."),
        ])
    }

    func testResultArrivingInLaterChunkAttaches() {
        var transcript = ClaudeTranscript()
        transcript.ingest(lines[4])
        transcript.ingest(#"{"type":"user","uuid":"r","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"boom"}],"is_error":true}]}}"#)
        guard case .tool(let tool) = transcript.items.first else { return XCTFail() }
        XCTAssertEqual(tool.result, "boom")
        XCTAssertTrue(tool.isError)
    }

    func testLimitKeepsToolIndexValid() {
        var transcript = ClaudeTranscript()
        transcript.limit = 2
        transcript.ingest(lines[1])
        transcript.ingest(lines[4])
        transcript.ingest(lines[3])
        transcript.ingest(lines[5])
        XCTAssertEqual(transcript.items.count, 2)
        guard case .tool(let tool) = transcript.items[0] else { return XCTFail("\(transcript.items)") }
        XCTAssertEqual(tool.result, "2 passing")
    }

    func testSameFolderAgentsAreAmbiguousWithoutSessionInfo() {
        func claude(_ pane: String, cwd: String, session: String? = nil) -> AgentInfo {
            AgentInfo(terminalId: pane, name: nil, agent: "claude", title: nil, terminalTitleStripped: nil,
                      displayAgent: nil, agentStatus: .idle, workspaceId: "w1", tabId: "t", paneId: pane,
                      focused: false, stateChangeSeq: nil, completionSeq: nil, cwd: cwd, foregroundCwd: nil,
                      agentSession: session.map { AgentSessionInfo(kind: "session_id", value: $0) })
        }
        let a = claude("p1", cwd: "/lab"), b = claude("p2", cwd: "/lab"), c = claude("p3", cwd: "/other")
        XCTAssertTrue(SessionSnapshot(agents: [a, b, c]).transcriptIsAmbiguous(for: a))
        XCTAssertFalse(SessionSnapshot(agents: [a, b, c]).transcriptIsAmbiguous(for: c))
        let reported = claude("p1", cwd: "/lab", session: "abc")
        XCTAssertFalse(SessionSnapshot(agents: [reported, b]).transcriptIsAmbiguous(for: reported))
    }

    func testSessionInfoInBothShapes() throws {
        let decoder = HerdrResponse.decoder()
        let new = try decoder.decode(AgentSessionInfo.self, from: Data(#"{"source":"claude","agent":"claude","kind":"session_id","value":"abc"}"#.utf8))
        XCTAssertEqual(new.id, "abc")
        XCTAssertNil(new.path)
        let old = try decoder.decode(AgentSessionInfo.self, from: Data(#"{"source":"claude","agent":"claude","session_id":"abc","session_path":"/h/.claude/projects/p/abc.jsonl"}"#.utf8))
        XCTAssertEqual(old.path, "/h/.claude/projects/p/abc.jsonl")
        XCTAssertTrue(TranscriptFetch.command(session: old, cwd: nil, known: nil)!.contains("f=/h/.claude/projects/p/abc.jsonl;"))
    }

    func testProjectDirectoryMatchesClaudeCode() {
        XCTAssertEqual(TranscriptFetch.claudeProjectDirectory(for: "/Users/vaclis./Documents/project/herdr-ios-app"),
                       "-Users-vaclis--Documents-project-herdr-ios-app")
        XCTAssertEqual(TranscriptFetch.claudeProjectDirectory(for: "/home/me/project"), "-home-me-project")
    }

    func testCommandLocatesBySessionThenCwd() {
        let byID = TranscriptFetch.command(session: AgentSessionInfo(kind: "session_id", value: "abc-123"), cwd: "/x", known: nil)!
        XCTAssertTrue(byID.contains(#".claude/projects/*/abc-123.jsonl"#))
        let unsafeID = TranscriptFetch.command(session: AgentSessionInfo(kind: "session_id", value: "a;rm -rf"), cwd: "/x", known: nil)!
        XCTAssertTrue(unsafeID.contains(".claude/projects/-x/*.jsonl"), "unsafe ids fall back to the cwd lookup")
        let byPath = TranscriptFetch.command(session: AgentSessionInfo(kind: "session_path", value: "/p/s.jsonl"), cwd: nil, known: nil)!
        XCTAssertTrue(byPath.contains("f=/p/s.jsonl;"))
        let incremental = TranscriptFetch.command(session: nil, cwd: "/x", known: ("/p/s.jsonl", 100))!
        XCTAssertTrue(incremental.contains("tail -c +101"))
        XCTAssertNil(TranscriptFetch.command(session: nil, cwd: nil, known: nil))
    }

    func testNoFolderGuessWhenAmbiguous() {
        XCTAssertNil(TranscriptFetch.command(session: nil, cwd: "/lab", allowFolderGuess: false, known: nil))
        let script = TranscriptFetch.command(session: nil, processInfo: "true", cwd: "/lab", allowFolderGuess: false, known: nil)!
        XCTAssertFalse(script.contains("projects/-lab/"))
    }

    /// pane process -> ~/.claude/sessions/<pid>.json -> ~/.claude/projects/*/<session>.jsonl
    func testLocatesTranscriptThroughPaneProcess() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: home.appendingPathComponent(".claude/sessions"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent(".claude/projects/-lab"), withIntermediateDirectories: true)
        try #"{"pid":4242,"sessionId":"sess-b","cwd":"/lab"}"#.write(to: home.appendingPathComponent(".claude/sessions/4242.json"), atomically: true, encoding: .utf8)
        // Two transcripts in the same folder; the newer one belongs to the other Claude.
        try (lines[1] + "\n").write(to: home.appendingPathComponent(".claude/projects/-lab/sess-b.jsonl"), atomically: true, encoding: .utf8)
        Thread.sleep(forTimeInterval: 1.1)
        try (lines[3] + "\n").write(to: home.appendingPathComponent(".claude/projects/-lab/sess-a.jsonl"), atomically: true, encoding: .utf8)

        let info = #"printf '%s' '{"result":{"process_info":{"foreground_process_group_id":4242,"foreground_processes":[{"pid":4242},{"pid":99}]}}}'"#
        let script = TranscriptFetch.command(session: nil, processInfo: info, cwd: "/lab", allowFolderGuess: false, known: nil)!
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let chunk = try XCTUnwrap(TranscriptFetch.parse(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)))
        XCTAssertTrue(chunk.path.hasSuffix("sess-b.jsonl"), chunk.path)
    }

    func testParseKeepsOnlyCompleteLines() {
        let chunk = TranscriptFetch.parse("/p/s.jsonl\n120\ninc\n{\"a\":1}\n{\"b\":")
        XCTAssertEqual(chunk?.path, "/p/s.jsonl")
        XCTAssertEqual(chunk?.isIncremental, true)
        XCTAssertEqual(chunk?.body, "{\"a\":1}\n")
        XCTAssertEqual(chunk?.consumed, 120 - 5, "the partial line is read again next time")
        XCTAssertNil(TranscriptFetch.parse("garbage"))
    }

    func testScriptRunsAgainstRealFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("s.jsonl")
        try (lines[1] + "\n").write(to: file, atomically: true, encoding: .utf8)
        let session = AgentSessionInfo(kind: "session_path", value: file.path)

        func run(_ known: (String, Int)?) throws -> TranscriptFetch.Chunk? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", TranscriptFetch.command(session: session, cwd: nil, known: known)!]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            return TranscriptFetch.parse(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }

        let first = try XCTUnwrap(run(nil))
        XCTAssertFalse(first.isIncremental)
        var transcript = ClaudeTranscript()
        transcript.ingest(first.body)

        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(Data((lines[3] + "\n").utf8))
        try handle.close()

        let second = try XCTUnwrap(run((first.path, first.consumed)))
        XCTAssertTrue(second.isIncremental)
        transcript.ingest(second.body)
        XCTAssertEqual(transcript.items.count, 2)
    }
}
