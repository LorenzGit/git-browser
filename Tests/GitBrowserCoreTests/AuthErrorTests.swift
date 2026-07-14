import XCTest
@testable import GitBrowserCore

final class AuthErrorTests: XCTestCase {
    func testClassifierRecognizesRealGHOutput() {
        // Verbatim gh output on a machine that has never signed in.
        XCTAssertTrue(GHCLIClient.indicatesAuthenticationFailure("""
        To get started with GitHub CLI, please run:  gh auth login
        Alternatively, populate the GH_TOKEN environment variable with a GitHub API authentication token.
        """))
        XCTAssertTrue(GHCLIClient.indicatesAuthenticationFailure(
            "HTTP 401: Bad credentials (https://api.github.com/repos/a/b)"
        ))
        XCTAssertTrue(GHCLIClient.indicatesAuthenticationFailure(
            "gh: Not logged in to any GitHub hosts."
        ))
    }

    func testClassifierDoesNotOvermatch() {
        XCTAssertFalse(GHCLIClient.indicatesAuthenticationFailure(
            "HTTP 404: Not Found (https://api.github.com/repos/a/b)"
        ))
        XCTAssertFalse(GHCLIClient.indicatesAuthenticationFailure(
            "error connecting to api.github.com: network timeout"
        ))
        XCTAssertFalse(GHCLIClient.indicatesAuthenticationFailure(""))
    }

    /// End to end through ProcessRunner: a stub gh that prints the real
    /// unauthenticated message must surface as .notAuthenticated.
    func testUnauthenticatedGHMapsToNotAuthenticated() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitbrowser-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let stub = dir.appendingPathComponent("fake-gh")
        try """
        #!/bin/sh
        echo "To get started with GitHub CLI, please run:  gh auth login" >&2
        exit 4
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let client = GHCLIClient(ghExecutable: stub)
        do {
            _ = try await client.fetchMetadata(
                for: RepoCoordinates(host: "github.com", owner: "acme", repo: "x")
            )
            XCTFail("expected notAuthenticated")
        } catch GitHubClientError.notAuthenticated {
            // expected
        }
    }

    func testNotAuthenticatedMessageIsActionable() {
        let message = GitHubClientError.notAuthenticated.errorDescription ?? ""
        XCTAssertTrue(message.contains("gh auth login"), "must tell the user the exact command")
        XCTAssertTrue(message.contains("never handles GitHub credentials"),
                      "must state that the app does not do auth itself")
    }
}
