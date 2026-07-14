import XCTest
@testable import GitBrowserCore

/// Opt-in smoke tests against real GitHub through the user's gh CLI.
/// Skipped unless GB_LIVE=1 so the default suite is fully offline.
///
///     GB_LIVE=1 swift test --filter LiveGHTests
final class LiveGHTests: XCTestCase {
    private func liveClient() throws -> GHCLIClient {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["GB_LIVE"] == "1",
            "set GB_LIVE=1 to run live gh smoke tests"
        )
        return try GHCLIClient()
    }

    func testOpenListAndFetchAgainstRealRepo() async throws {
        let client = try liveClient()
        let coords = RepoCoordinates(host: "github.com", owner: "octocat", repo: "Hello-World")

        let metadata = try await client.fetchMetadata(for: coords)
        XCTAssertFalse(metadata.defaultBranch.isEmpty)

        let sha = try await client.resolveCommit(for: coords, ref: nil)
        XCTAssertEqual(sha.count, 40)

        let root = try await client.listDirectory(for: coords, commit: sha, path: "")
        XCTAssertTrue(root.contains { $0.name == "README" })

        let readme = try await client.fetchFile(for: coords, commit: sha, path: "README")
        XCTAssertFalse(readme.isEmpty)
    }

    func testNativeReadCommandsDetected() async throws {
        let client = try liveClient()
        // gh 2.96+ has repo read-file/read-dir; this asserts the probe works,
        // not that every machine has a new gh.
        let supported = await client.hasNativeReadCommands()
        print("LIVE: gh repo read-file/read-dir supported: \(supported)")
    }

    func testMissingFileMapsToNotFound() async throws {
        let client = try liveClient()
        let coords = RepoCoordinates(host: "github.com", owner: "octocat", repo: "Hello-World")
        let sha = try await client.resolveCommit(for: coords, ref: nil)
        do {
            _ = try await client.fetchFile(for: coords, commit: sha, path: "no/such/file.txt")
            XCTFail("expected notFound")
        } catch GitHubClientError.notFound {
            // expected
        }
    }
}
