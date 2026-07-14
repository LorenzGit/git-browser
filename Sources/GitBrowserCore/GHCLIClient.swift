import Foundation

/// GitHubClient backed by the user's existing authenticated GitHub CLI.
///
/// Prefers `gh repo read-dir` / `gh repo read-file` when the installed gh
/// supports them (they are preview commands), and falls back to `gh api`
/// against GitHub's read-only repository APIs otherwise.
///
/// gh is always invoked via Process with a resolved executable URL and an
/// argument array — never through a shell. The app never reads, prints,
/// stores, or logs the GitHub token; authentication stays entirely inside gh.
public final class GHCLIClient: GitHubClient, @unchecked Sendable {
    private let ghURL: URL

    /// nil = not probed yet.
    private var supportsReadCommands: Bool?
    private let probeLock = NSLock()

    public init() throws {
        guard let url = Self.locateGH() else {
            throw GitHubClientError.ghNotFound
        }
        ghURL = url
    }

    public init(ghExecutable: URL) {
        ghURL = ghExecutable
    }

    /// Finds gh in PATH plus the usual install locations.
    static func locateGH() -> URL? {
        var candidates: [String] = []
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/gh" }
        }
        candidates += ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        let fm = FileManager.default
        for candidate in candidates where fm.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    // MARK: - Feature detection

    /// Feature-detects the preview read-dir/read-file commands (once).
    func hasNativeReadCommands() async -> Bool {
        if let known = cachedProbeResult() { return known }

        let supported: Bool
        if let result = try? await ProcessRunner.run(
            executable: ghURL, arguments: ["repo", "read-file", "--help"]
        ), result.status == 0 {
            supported = true
        } else {
            supported = false
        }
        storeProbeResult(supported)
        return supported
    }

    private func cachedProbeResult() -> Bool? {
        probeLock.lock(); defer { probeLock.unlock() }
        return supportsReadCommands
    }

    private func storeProbeResult(_ value: Bool) {
        probeLock.lock(); defer { probeLock.unlock() }
        supportsReadCommands = value
    }

    // MARK: - Helpers

    /// [HOST/]OWNER/REPO selector for `--repo` flags.
    private func repoSelector(_ repo: RepoCoordinates) -> String {
        repo.host == "github.com"
            ? "\(repo.owner)/\(repo.repo)"
            : "\(repo.host)/\(repo.owner)/\(repo.repo)"
    }

    private func apiArguments(_ repo: RepoCoordinates, endpoint: String, extra: [String] = []) -> [String] {
        var args = ["api"]
        if repo.host != "github.com" {
            args += ["--hostname", repo.host]
        }
        args += extra
        args.append(endpoint)
        return args
    }

    private func percentEncodePath(_ path: String) -> String {
        path.split(separator: "/").map { segment in
            String(segment).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed2) ?? String(segment)
        }.joined(separator: "/")
    }

    /// Recognizes gh's "not signed in / bad token" stderr so it can surface
    /// as a dedicated, actionable error. The app only ever *tells* the user
    /// to run `gh auth login`; it never initiates authentication itself.
    static func indicatesAuthenticationFailure(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        let markers = [
            "gh auth login",
            "http 401",
            "bad credentials",
            "gh_token",
            "not logged in",
            "authentication required",
        ]
        return markers.contains { lowered.contains($0) }
    }

    private func runGH(_ arguments: [String]) async throws -> Data {
        let result = try await ProcessRunner.run(executable: ghURL, arguments: arguments)
        guard result.status == 0 else {
            let stderr = result.stderrText
            if Self.indicatesAuthenticationFailure(stderr) {
                throw GitHubClientError.notAuthenticated
            }
            if stderr.contains("HTTP 404") || stderr.contains("Not Found") || stderr.contains("no commit found") {
                throw GitHubClientError.notFound(arguments.last ?? "")
            }
            // Redact nothing but include the command *name* only, never env.
            throw GitHubClientError.commandFailed(
                command: arguments.prefix(2).joined(separator: " "),
                status: result.status,
                stderr: String(stderr.prefix(500))
            )
        }
        return result.stdout
    }

    // MARK: - GitHubClient

    public func fetchMetadata(for repo: RepoCoordinates) async throws -> RepoMetadata {
        let data = try await runGH(apiArguments(repo, endpoint: "repos/\(repo.owner)/\(repo.repo)"))
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let defaultBranch = object["default_branch"] as? String
        else {
            throw GitHubClientError.invalidResponse("repository metadata")
        }
        return RepoMetadata(
            fullName: object["full_name"] as? String ?? repo.displayName,
            defaultBranch: defaultBranch,
            description: object["description"] as? String,
            isPrivate: object["private"] as? Bool ?? false
        )
    }

    public func resolveCommit(for repo: RepoCoordinates, ref: String?) async throws -> String {
        let refName: String
        if let ref, !ref.isEmpty {
            refName = ref
        } else {
            refName = try await fetchMetadata(for: repo).defaultBranch
        }
        let encoded = refName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed2) ?? refName
        let data = try await runGH(apiArguments(
            repo,
            endpoint: "repos/\(repo.owner)/\(repo.repo)/commits/\(encoded)",
            extra: ["--jq", ".sha"]
        ))
        let sha = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard sha.count == 40, sha.allSatisfy({ $0.isHexDigit }) else {
            throw GitHubClientError.invalidResponse("commit SHA for ref '\(refName)'")
        }
        return sha
    }

    public func listDirectory(for repo: RepoCoordinates, commit: String, path: String) async throws -> [DirEntry] {
        if await hasNativeReadCommands() {
            var args = ["repo", "read-dir"]
            if !path.isEmpty { args.append(path) }
            args += [
                "--repo", repoSelector(repo),
                "--ref", commit,
                "--json", "name,path,type,size",
            ]
            let data = try await runGH(args)
            return try Self.parseReadDirJSON(data)
        }
        // Fallback: contents API returns the immediate children of one directory.
        let endpoint = "repos/\(repo.owner)/\(repo.repo)/contents/\(percentEncodePath(path))?ref=\(commit)"
        let data = try await runGH(apiArguments(repo, endpoint: endpoint))
        return try Self.parseContentsAPIJSON(data)
    }

    public func fetchFile(for repo: RepoCoordinates, commit: String, path: String) async throws -> Data {
        if await hasNativeReadCommands() {
            // Piped output is raw bytes; --allow-escape-sequences keeps gh from
            // refusing binary content.
            return try await runGH([
                "repo", "read-file", path,
                "--repo", repoSelector(repo),
                "--ref", commit,
                "--allow-escape-sequences",
            ])
        }
        // Fallback: contents API with the raw media type returns the bytes.
        let endpoint = "repos/\(repo.owner)/\(repo.repo)/contents/\(percentEncodePath(path))?ref=\(commit)"
        return try await runGH(apiArguments(
            repo, endpoint: endpoint,
            extra: ["-H", "Accept: application/vnd.github.raw+json"]
        ))
    }

    // MARK: - Parsing

    static func parseReadDirJSON(_ data: Data) throws -> [DirEntry] {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = object["entries"] as? [[String: Any]]
        else {
            throw GitHubClientError.invalidResponse("read-dir output")
        }
        return entries.compactMap(Self.entry(fromJSON:))
    }

    static func parseContentsAPIJSON(_ data: Data) throws -> [DirEntry] {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            // A single object means the path was a file, not a directory.
            throw GitHubClientError.invalidResponse("directory listing")
        }
        return entries.compactMap(Self.entry(fromJSON:))
    }

    private static func entry(fromJSON json: [String: Any]) -> DirEntry? {
        guard let name = json["name"] as? String, let path = json["path"] as? String else {
            return nil
        }
        let typeRaw = json["type"] as? String ?? "other"
        let type = DirEntryType(rawValue: typeRaw) ?? .other
        let size = (json["size"] as? NSNumber)?.int64Value ?? 0
        return DirEntry(name: name, path: path, type: type, size: size)
    }
}

extension CharacterSet {
    /// URL path segment characters, excluding characters that are legal in
    /// git paths but need escaping in a URL path segment.
    static let urlPathAllowed2: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/?#%")
        return set
    }()
}
