import Foundation

/// GitHubClient backed by a local folder instead of a remote repository.
///
/// The "working tree" pseudo-commit serves whatever is on disk right now.
/// When the folder is a git repository, real refs work too: sessions can pin
/// to a branch, tag, or commit and content is served from git's object store
/// (`git show`, `git ls-tree`), which powers the branch switcher and file
/// time travel for local repos.
///
/// Local content flows through the same repobrowser:// scheme handler as
/// remote content — WKWebView never gets file:// access, and every path is
/// validated against the selected root.
public final class LocalFolderClient: GitHubClient, @unchecked Sendable {
    /// Sentinel "commit" meaning: serve the files currently on disk.
    public static let workingTreeRef = "working-tree"

    public let rootURL: URL
    public let isGitRepository: Bool
    private let gitURL = URL(fileURLWithPath: "/usr/bin/git")

    public init(rootURL: URL) {
        let resolved = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.rootURL = resolved
        isGitRepository = FileManager.default.fileExists(
            atPath: resolved.appendingPathComponent(".git").path
        )
    }

    /// Synthetic coordinates so sessions/UI can treat local folders like repos.
    public static func coordinates(for rootURL: URL) -> RepoCoordinates {
        let standardized = rootURL.standardizedFileURL
        let parent = standardized.deletingLastPathComponent().lastPathComponent
        return RepoCoordinates(
            host: "local",
            owner: parent.isEmpty ? "folder" : parent,
            repo: standardized.lastPathComponent
        )
    }

    // MARK: - Path safety

    /// Maps a repo-relative path onto disk, refusing anything that is not a
    /// clean, root-contained relative path.
    private func diskURL(for path: String) throws -> URL {
        guard let normalized = RepoPath.normalize(path), normalized == path else {
            throw GitHubClientError.notFound(path)
        }
        return path.isEmpty ? rootURL : rootURL.appendingPathComponent(path)
    }

    private func runGit(_ arguments: [String]) async throws -> Data {
        let result = try await ProcessRunner.run(
            executable: gitURL, arguments: ["-C", rootURL.path] + arguments
        )
        guard result.status == 0 else {
            let stderr = result.stderrText
            if stderr.contains("does not exist") || stderr.contains("exists on disk, but not in")
                || stderr.contains("unknown revision") || stderr.contains("bad revision") {
                throw GitHubClientError.notFound(arguments.last ?? "")
            }
            throw GitHubClientError.commandFailed(
                command: "git " + arguments.prefix(2).joined(separator: " "),
                status: result.status,
                stderr: String(stderr.prefix(300))
            )
        }
        return result.stdout
    }

    // MARK: - GitHubClient

    public func fetchMetadata(for repo: RepoCoordinates) async throws -> RepoMetadata {
        var branch = Self.workingTreeRef
        if isGitRepository,
           let data = try? await runGit(["rev-parse", "--abbrev-ref", "HEAD"]),
           let name = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            branch = name
        }
        return RepoMetadata(
            fullName: rootURL.lastPathComponent,
            defaultBranch: branch,
            description: rootURL.path,
            isPrivate: true
        )
    }

    public func resolveCommit(for repo: RepoCoordinates, ref: String?) async throws -> String {
        guard let ref, !ref.isEmpty, ref != Self.workingTreeRef else {
            return Self.workingTreeRef
        }
        guard isGitRepository else {
            throw GitHubClientError.notFound("ref \(ref) (not a git repository)")
        }
        let data = try await runGit(["rev-parse", "--verify", "\(ref)^{commit}"])
        let sha = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard sha.count == 40 else {
            throw GitHubClientError.invalidResponse("commit for ref '\(ref)'")
        }
        return sha
    }

    public func listDirectory(for repo: RepoCoordinates, commit: String, path: String) async throws -> [DirEntry] {
        if commit == Self.workingTreeRef {
            return try listWorkingTreeDirectory(path: path)
        }
        var args = ["ls-tree", "-l", commit]
        if !path.isEmpty { args.append("\(path)/") }
        let data = try await runGit(args)
        return Self.parseLsTree(data).map { item in
            DirEntry(
                name: RepoPath.fileName(of: item.path),
                path: item.path, type: item.type, size: item.size
            )
        }
    }

    public func fetchFile(for repo: RepoCoordinates, commit: String, path: String) async throws -> Data {
        if commit == Self.workingTreeRef {
            let url = try diskURL(for: path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else {
                throw GitHubClientError.notFound(path)
            }
            return try Data(contentsOf: url)
        }
        _ = try diskURL(for: path) // path shape validation only
        return try await runGit(["show", "\(commit):\(path)"])
    }

    public func fullTree(for repo: RepoCoordinates, commit: String) async throws -> FullTree {
        if commit == Self.workingTreeRef {
            return workingTreeFullTree()
        }
        let data = try await runGit(["ls-tree", "-r", "-l", commit])
        let entries = Self.parseLsTree(data).map {
            TreeEntry(path: $0.path, type: $0.type, size: $0.size)
        }
        return FullTree(entries: entries, truncated: false)
    }

    public func listBranches(for repo: RepoCoordinates) async throws -> [String] {
        guard isGitRepository else { return [] }
        let data = try await runGit(["branch", "--format=%(refname:short)"])
        return Self.nonEmptyLines(data)
    }

    public func listTags(for repo: RepoCoordinates) async throws -> [String] {
        guard isGitRepository else { return [] }
        let data = try await runGit(["tag", "--list"])
        return Self.nonEmptyLines(data)
    }

    public func fileHistory(for repo: RepoCoordinates, ref: String, path: String) async throws -> [CommitInfo] {
        guard isGitRepository else { return [] }
        let target = ref == Self.workingTreeRef ? "HEAD" : ref
        let data = try await runGit([
            "log", target, "--max-count=50",
            "--format=%H%x09%an%x09%aI%x09%s", "--", path,
        ])
        return Self.nonEmptyLines(data).compactMap { line in
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 4, parts[0].count == 40 else { return nil }
            return CommitInfo(sha: parts[0], summary: parts[3], authorName: parts[1], date: parts[2])
        }
    }

    public func searchCode(for repo: RepoCoordinates, query: String) async throws -> [CodeSearchResult] {
        throw GitHubClientError.invalidResponse(
            "Code search is a GitHub server feature and isn't available for local folders"
        )
    }

    // MARK: - Working tree access

    private func listWorkingTreeDirectory(path: String) throws -> [DirEntry] {
        let directory = try diskURL(for: path)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: []
        ) else {
            throw GitHubClientError.notFound(path)
        }
        return children.compactMap { child in
            let name = child.lastPathComponent
            if name == ".git" { return nil }
            let values = try? child.resourceValues(forKeys: Set(keys))
            let type: DirEntryType
            if values?.isSymbolicLink == true {
                type = .symlink
            } else if values?.isDirectory == true {
                type = .dir
            } else {
                type = .file
            }
            let childPath = path.isEmpty ? name : "\(path)/\(name)"
            return DirEntry(
                name: name, path: childPath, type: type,
                size: Int64(values?.fileSize ?? 0)
            )
        }
    }

    private func workingTreeFullTree() -> FullTree {
        var entries: [TreeEntry] = []
        var truncated = false
        let limit = 200_000
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let enumerator = FileManager.default.enumerator(
            at: rootURL, includingPropertiesForKeys: keys, options: []
        )
        let rootPath = rootURL.path
        while let item = enumerator?.nextObject() as? URL {
            let name = item.lastPathComponent
            let values = try? item.resourceValues(forKeys: Set(keys))
            if name == ".git", values?.isDirectory == true {
                enumerator?.skipDescendants()
                continue
            }
            guard entries.count < limit else {
                truncated = true
                break
            }
            let relative = String(
                item.standardizedFileURL.path.dropFirst(rootPath.count)
            ).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relative.isEmpty else { continue }
            entries.append(TreeEntry(
                path: relative,
                type: values?.isDirectory == true ? .dir : .file,
                size: Int64(values?.fileSize ?? 0)
            ))
        }
        return FullTree(entries: entries, truncated: truncated)
    }

    // MARK: - Parsing

    struct LsTreeItem {
        var path: String
        var type: DirEntryType
        var size: Int64
    }

    /// Parses `git ls-tree -l` output:
    /// `<mode> <type> <sha> <size-or-dash>\t<path>` per line.
    static func parseLsTree(_ data: Data) -> [LsTreeItem] {
        nonEmptyLines(data).compactMap { line in
            guard let tab = line.firstIndex(of: "\t") else { return nil }
            let meta = line[..<tab].split(separator: " ", omittingEmptySubsequences: true)
            let path = String(line[line.index(after: tab)...])
            guard meta.count >= 3, !path.isEmpty else { return nil }
            let mode = meta[0]
            let objectType = meta[1]
            let size = meta.count >= 4 ? Int64(meta[3]) ?? 0 : 0
            let type: DirEntryType
            if mode == "120000" {
                type = .symlink
            } else {
                switch objectType {
                case "tree": type = .dir
                case "blob": type = .file
                case "commit": type = .submodule
                default: type = .other
                }
            }
            return LsTreeItem(path: path, type: type, size: size)
        }
    }

    static func nonEmptyLines(_ data: Data) -> [String] {
        (String(data: data, encoding: .utf8) ?? "")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
