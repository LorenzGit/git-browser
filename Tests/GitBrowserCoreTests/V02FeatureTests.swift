import XCTest
@testable import GitBrowserCore

final class PullRequestURLTests: XCTestCase {
    func testPullURL() {
        let p = GitHubRepoURLParser.parse("https://github.com/cli/cli/pull/1234")
        XCTAssertEqual(p?.pullRequest, 1234)
        XCTAssertNil(p?.ref)
    }

    func testPullURLWithSubpage() {
        let p = GitHubRepoURLParser.parse("https://github.com/cli/cli/pull/77/files")
        XCTAssertEqual(p?.pullRequest, 77)
    }

    func testInvalidPullNumberFallsBackToRepo() {
        let p = GitHubRepoURLParser.parse("https://github.com/cli/cli/pull/abc")
        XCTAssertNil(p?.pullRequest)
        XCTAssertEqual(p?.coordinates.repo, "cli")
    }
}

final class FuzzyMatcherTests: XCTestCase {
    func testSubsequenceRequired() {
        XCTAssertNotNil(FuzzyMatcher.score(candidate: "Sources/GitBrowser/main.swift", query: "main"))
        XCTAssertNil(FuzzyMatcher.score(candidate: "main.swift", query: "xyz"))
        XCTAssertNil(FuzzyMatcher.score(candidate: "ab", query: "abc"))
    }

    func testCaseInsensitive() {
        XCTAssertNotNil(FuzzyMatcher.score(candidate: "README.md", query: "readme"))
    }

    func testBoundaryMatchesBeatScattered() {
        // "mwc" as initials of MainWindowController vs scattered letters.
        let initials = FuzzyMatcher.score(candidate: "app/main-window-controller.swift", query: "mwc")!
        let scattered = FuzzyMatcher.score(candidate: "somewhatrandomwordcatalog.txt", query: "mwc")!
        XCTAssertGreaterThan(initials, scattered)
    }

    func testRankPrefersFileNameHit() {
        let ranked = FuzzyMatcher.rank(
            candidates: [
                "docs/very/long/path/that/contains/setup/notes.txt",
                "setup.py",
            ],
            query: "setup"
        )
        XCTAssertEqual(ranked.first, "setup.py")
    }

    func testEmptyQueryReturnsPrefix() {
        let ranked = FuzzyMatcher.rank(candidates: ["a", "b", "c"], query: "", limit: 2)
        XCTAssertEqual(ranked, ["a", "b"])
    }
}

final class MarkdownFenceHighlightTests: XCTestCase {
    func testSwiftFenceGetsTokenSpans() {
        let html = MarkdownRenderer.renderBody(markdown: "```swift\nlet x = 42 // hi\n```")
        XCTAssertTrue(html.contains("<span class=\"kw\">let</span>"), html)
        XCTAssertTrue(html.contains("<span class=\"num\">42</span>"), html)
        XCTAssertTrue(html.contains("<span class=\"com\">// hi</span>"), html)
    }

    func testLanguageAliasesMap() {
        let html = MarkdownRenderer.renderBody(markdown: "```python\ndef f(): pass\n```")
        XCTAssertTrue(html.contains("<span class=\"kw\">def</span>"), html)
    }

    func testUnknownLanguageStillEscapes() {
        let html = MarkdownRenderer.renderBody(markdown: "```weird\n<b>&x</b>\n```")
        XCTAssertTrue(html.contains("&lt;b&gt;&amp;x&lt;/b&gt;"), html)
        XCTAssertFalse(html.contains("<b>"))
    }
}

final class GHCLIParserTests: XCTestCase {
    func testParseTreeJSON() throws {
        let json = """
        {"sha":"abc","tree":[
          {"path":"README.md","mode":"100644","type":"blob","size":120},
          {"path":"docs","mode":"040000","type":"tree"},
          {"path":"docs/index.html","mode":"100644","type":"blob","size":900}
        ],"truncated":false}
        """
        let tree = try GHCLIClient.parseTreeJSON(Data(json.utf8))
        XCTAssertEqual(tree.entries.count, 3)
        XCTAssertFalse(tree.truncated)
        XCTAssertEqual(tree.entries[0].type, .file)
        XCTAssertEqual(tree.entries[1].type, .dir)
        XCTAssertEqual(tree.entries[2].path, "docs/index.html")
    }

    func testParseSearchJSON() throws {
        let json = """
        {"total_count":1,"items":[
          {"path":"src/app.js","text_matches":[{"fragment":"function main() {"}]}
        ]}
        """
        let results = try GHCLIClient.parseSearchJSON(Data(json.utf8))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].path, "src/app.js")
        XCTAssertEqual(results[0].fragments, ["function main() {"])
    }

    func testParseCommitsJSON() throws {
        let json = """
        [{"sha":"0123456789abcdef","commit":{
            "message":"Fix the widget\\n\\nLonger body",
            "author":{"name":"Ada","date":"2026-07-01T10:00:00Z"}
        }}]
        """
        let commits = try GHCLIClient.parseCommitsJSON(Data(json.utf8))
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].summary, "Fix the widget")
        XCTAssertEqual(commits[0].authorName, "Ada")
        XCTAssertEqual(commits[0].sha, "0123456789abcdef")
    }

    func testParsePullRequestJSON() throws {
        let json = """
        {"number":42,"title":"Improve docs","state":"open",
         "user":{"login":"ada"},
         "head":{"sha":"feedfacefeedfacefeedfacefeedfacefeedface","ref":"docs-work"},
         "base":{"ref":"main"}}
        """
        let pr = try GHCLIClient.parsePullRequestJSON(Data(json.utf8))
        XCTAssertEqual(pr.number, 42)
        XCTAssertEqual(pr.headSHA, "feedfacefeedfacefeedfacefeedfacefeedface")
        XCTAssertEqual(pr.headRef, "docs-work")
        XCTAssertEqual(pr.baseRef, "main")
        XCTAssertEqual(pr.author, "ada")
    }

    func testParsePullRequestFilesSlurpedPages() throws {
        let json = """
        [
          [{"filename":"a.html","status":"modified","additions":3,"deletions":1}],
          [{"filename":"b.css","status":"added","additions":10,"deletions":0},
           {"filename":"old.js","status":"renamed","previous_filename":"ancient.js","additions":0,"deletions":0}]
        ]
        """
        let files = try GHCLIClient.parsePullRequestFilesJSON(Data(json.utf8))
        XCTAssertEqual(files.count, 3)
        XCTAssertEqual(files[0].path, "a.html")
        XCTAssertEqual(files[1].status, "added")
        XCTAssertEqual(files[2].previousPath, "ancient.js")
    }

    func testParseStringArray() throws {
        let names = try GHCLIClient.parseStringArray(Data("[\"main\",\"dev\"]".utf8), what: "branches")
        XCTAssertEqual(names, ["main", "dev"])
    }
}
