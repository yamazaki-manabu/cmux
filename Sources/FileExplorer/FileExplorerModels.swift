import Foundation

enum FileExplorerHostScope: Hashable, Sendable {
    case local
    case ssh(destination: String, port: Int?, identityFingerprint: String?)
}

enum FileExplorerNodeID: Hashable, Sendable {
    case path(hostScope: FileExplorerHostScope, canonicalPath: String)

    var hostScope: FileExplorerHostScope {
        switch self {
        case .path(let hostScope, _):
            hostScope
        }
    }

    var canonicalPath: String {
        switch self {
        case .path(_, let canonicalPath):
            canonicalPath
        }
    }
}

struct FileExplorerRootInput: Equatable, Sendable {
    let panelID: UUID
    let hostScope: FileExplorerHostScope
    let rawDirectory: String

    static func local(panelID: UUID, directory: String) -> Self {
        Self(panelID: panelID, hostScope: .local, rawDirectory: directory)
    }

    static func ssh(
        panelID: UUID,
        destination: String,
        port: Int? = nil,
        identityFingerprint: String? = nil,
        directory: String
    ) -> Self {
        Self(
            panelID: panelID,
            hostScope: .ssh(
                destination: destination,
                port: port,
                identityFingerprint: identityFingerprint
            ),
            rawDirectory: directory
        )
    }
}

struct FileExplorerResolvedNode: Equatable, Sendable, Identifiable {
    let id: FileExplorerNodeID
    let hostScope: FileExplorerHostScope
    let canonicalPath: String
    let displayPath: String
    let name: String
    let referencedPanelIDs: [UUID]
    let children: [FileExplorerResolvedNode]

    var isExplicitSurfaceRoot: Bool {
        !referencedPanelIDs.isEmpty
    }

    func containsReferencedDescendant(_ path: String) -> Bool {
        children.contains { $0.matchesReferencedPath(path) }
    }

    private func matchesReferencedPath(_ path: String) -> Bool {
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        if isExplicitSurfaceRoot,
           displayPath == normalized || canonicalPath == normalized {
            return true
        }
        return children.contains { $0.matchesReferencedPath(normalized) }
    }
}

struct FileExplorerResolvedRoot: Equatable, Sendable, Identifiable {
    let node: FileExplorerResolvedNode

    var id: FileExplorerNodeID { node.id }
    var hostScope: FileExplorerHostScope { node.hostScope }
    var canonicalPath: String { node.canonicalPath }
    var displayPath: String { node.displayPath }
    var name: String { node.name }
    var referencedPanelIDs: [UUID] { node.referencedPanelIDs }
    var children: [FileExplorerResolvedNode] { node.children }

    func containsReferencedDescendant(_ path: String) -> Bool {
        node.containsReferencedDescendant(path)
    }
}

struct FileExplorerListRequest: Equatable, Sendable {
    let nodeID: FileExplorerNodeID

    var hostScope: FileExplorerHostScope { nodeID.hostScope }
    var canonicalPath: String { nodeID.canonicalPath }
}

enum FileExplorerEntryKind: String, Equatable, Sendable {
    case directory
    case file
    case symlink
}

struct FileExplorerEntry: Equatable, Sendable, Identifiable {
    let hostScope: FileExplorerHostScope
    let canonicalPath: String
    let displayName: String
    let kind: FileExplorerEntryKind
    let isHidden: Bool

    var id: FileExplorerNodeID {
        .path(hostScope: hostScope, canonicalPath: canonicalPath)
    }
}
