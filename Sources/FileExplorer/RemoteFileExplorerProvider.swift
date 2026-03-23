import Foundation

enum RemoteFileExplorerProviderError: LocalizedError {
    case hostScopeMismatch
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .hostScopeMismatch:
            "Remote file explorer request did not match the active SSH target."
        case .invalidResponse(let detail):
            detail
        }
    }
}

struct RemoteFileExplorerProvider: FileExplorerProvider {
    struct ListedEntry: Equatable, Sendable {
        let canonicalPath: String
        let displayName: String
        let kind: FileExplorerEntryKind
    }

    typealias ListEntries = @Sendable (_ path: String, _ configuration: WorkspaceRemoteConfiguration, _ remotePath: String) async throws -> [ListedEntry]

    let configuration: WorkspaceRemoteConfiguration
    let remotePath: String

    private let listEntries: ListEntries

    private static let defaultListEntries: ListEntries = { path, configuration, remotePath in
        try await Self.liveListEntries(path: path, configuration: configuration, remotePath: remotePath)
    }

    init(
        configuration: WorkspaceRemoteConfiguration,
        remotePath: String,
        listEntries: @escaping ListEntries = Self.defaultListEntries
    ) {
        self.configuration = configuration
        self.remotePath = remotePath
        self.listEntries = listEntries
    }

    func listChildren(for request: FileExplorerListRequest) async throws -> [FileExplorerEntry] {
        guard case .ssh = request.hostScope else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        guard request.hostScope == expectedHostScope else {
            throw RemoteFileExplorerProviderError.hostScopeMismatch
        }

        let listedEntries = try await listEntries(request.canonicalPath, configuration, remotePath)
        return listedEntries.map { entry in
            FileExplorerEntry(
                hostScope: request.hostScope,
                canonicalPath: entry.canonicalPath,
                displayName: entry.displayName,
                kind: entry.kind,
                isHidden: entry.displayName.hasPrefix(".")
            )
        }
    }

    private var expectedHostScope: FileExplorerHostScope {
        .ssh(
            destination: configuration.destination,
            port: configuration.port,
            identityFingerprint: configuration.proxyBrokerTransportKey
        )
    }

    private static func liveListEntries(
        path: String,
        configuration: WorkspaceRemoteConfiguration,
        remotePath: String
    ) async throws -> [ListedEntry] {
        try await Task.detached(priority: .utility) {
            let client = WorkspaceRemoteDaemonRPCClient(
                configuration: configuration,
                remotePath: remotePath,
                onUnexpectedTermination: { _ in }
            )
            try client.start()
            defer { client.stop() }

            let rawEntries = try client.listDirectory(path: path)
            return try rawEntries.map(parseListedEntry(_:))
        }.value
    }

    private static func parseListedEntry(_ rawEntry: [String: Any]) throws -> ListedEntry {
        let canonicalPath = (rawEntry["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayName = (rawEntry["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawKind = (rawEntry["kind"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !canonicalPath.isEmpty, !displayName.isEmpty else {
            throw RemoteFileExplorerProviderError.invalidResponse("fs.list returned an entry with missing path or name")
        }

        let kind: FileExplorerEntryKind
        switch rawKind {
        case FileExplorerEntryKind.directory.rawValue:
            kind = .directory
        case FileExplorerEntryKind.file.rawValue:
            kind = .file
        case FileExplorerEntryKind.symlink.rawValue:
            kind = .symlink
        default:
            throw RemoteFileExplorerProviderError.invalidResponse("fs.list returned unsupported kind '\(rawKind)'")
        }

        return ListedEntry(
            canonicalPath: canonicalPath,
            displayName: displayName,
            kind: kind
        )
    }
}
