import Foundation

struct FileExplorerNodeState: Equatable, Sendable, Identifiable {
    let id: FileExplorerNodeID
    let hostScope: FileExplorerHostScope
    let canonicalPath: String
    let displayName: String
    let displayPath: String
    let kind: FileExplorerEntryKind
    let isHidden: Bool
    let isExpanded: Bool
    let isLoading: Bool
    let errorMessage: String?
    let isExplicitSurfaceRoot: Bool
    let children: [FileExplorerNodeState]
}

struct FileExplorerTreeState: Equatable, Sendable {
    let roots: [FileExplorerNodeState]
}

actor FileExplorerStore {
    private let provider: FileExplorerProvider

    private var roots: [FileExplorerResolvedRoot] = []
    private var seedNodesByID: [FileExplorerNodeID: FileExplorerResolvedNode] = [:]
    private var loadedEntriesByParentID: [FileExplorerNodeID: [FileExplorerEntry]] = [:]
    private var expandedNodeIDs: Set<FileExplorerNodeID> = []
    private var loadingNodeIDs: Set<FileExplorerNodeID> = []
    private var errorMessagesByNodeID: [FileExplorerNodeID: String] = [:]

    init(provider: FileExplorerProvider) {
        self.provider = provider
    }

    func refreshRoots(_ roots: [FileExplorerResolvedRoot]) async {
        self.roots = roots
        seedNodesByID = Self.collectSeedNodes(from: roots)
        pruneDetachedState()
    }

    func toggleExpansion(for nodeID: FileExplorerNodeID) async {
        if expandedNodeIDs.contains(nodeID) {
            expandedNodeIDs.remove(nodeID)
            return
        }

        expandedNodeIDs.insert(nodeID)
        await loadChildren(for: nodeID, forceReload: false)
    }

    func refreshNode(_ nodeID: FileExplorerNodeID) async {
        await loadChildren(for: nodeID, forceReload: true)
    }

    func snapshot() -> FileExplorerTreeState {
        FileExplorerTreeState(
            roots: roots.map { buildNodeState(from: $0.node) }
        )
    }

    private func loadChildren(for nodeID: FileExplorerNodeID, forceReload: Bool) async {
        if !forceReload, loadedEntriesByParentID[nodeID] != nil {
            return
        }

        loadingNodeIDs.insert(nodeID)
        defer { loadingNodeIDs.remove(nodeID) }

        do {
            let entries = try await provider.listChildren(for: FileExplorerListRequest(nodeID: nodeID))
            loadedEntriesByParentID[nodeID] = entries
            errorMessagesByNodeID.removeValue(forKey: nodeID)
        } catch {
            errorMessagesByNodeID[nodeID] = error.localizedDescription
        }
    }

    private func pruneDetachedState() {
        let reachableSeedIDs = Set(seedNodesByID.keys)
        let reachableRootIDs = Set(roots.map(\.id))

        let isReachable: (FileExplorerNodeID) -> Bool = { nodeID in
            if reachableSeedIDs.contains(nodeID) || reachableRootIDs.contains(nodeID) {
                return true
            }
            return self.roots.contains { root in
                root.hostScope == nodeID.hostScope
                    && Self.isDescendantOrSelf(
                        canonicalPath: nodeID.canonicalPath,
                        of: root.canonicalPath
                    )
            }
        }

        loadedEntriesByParentID = loadedEntriesByParentID.filter { isReachable($0.key) }
        expandedNodeIDs = Set(expandedNodeIDs.filter(isReachable))
        loadingNodeIDs = Set(loadingNodeIDs.filter(isReachable))
        errorMessagesByNodeID = errorMessagesByNodeID.filter { isReachable($0.key) }
    }

    private func buildNodeState(
        from seedNode: FileExplorerResolvedNode,
        overrideEntry: FileExplorerEntry? = nil
    ) -> FileExplorerNodeState {
        let nodeID = seedNode.id
        let mergedChildren = mergedChildren(for: nodeID, seedChildren: seedNode.children)
        return FileExplorerNodeState(
            id: nodeID,
            hostScope: seedNode.hostScope,
            canonicalPath: seedNode.canonicalPath,
            displayName: overrideEntry?.displayName ?? seedNode.name,
            displayPath: seedNode.displayPath,
            kind: overrideEntry?.kind ?? .directory,
            isHidden: overrideEntry?.isHidden ?? false,
            isExpanded: expandedNodeIDs.contains(nodeID),
            isLoading: loadingNodeIDs.contains(nodeID),
            errorMessage: errorMessagesByNodeID[nodeID],
            isExplicitSurfaceRoot: seedNode.isExplicitSurfaceRoot,
            children: mergedChildren
        )
    }

    private func mergedChildren(
        for parentID: FileExplorerNodeID,
        seedChildren: [FileExplorerResolvedNode]
    ) -> [FileExplorerNodeState] {
        let seedChildrenByID = Dictionary(uniqueKeysWithValues: seedChildren.map { ($0.id, $0) })
        let loadedEntries = loadedEntriesByParentID[parentID] ?? []
        var mergedByID: [FileExplorerNodeID: FileExplorerNodeState] = [:]

        for entry in loadedEntries {
            if let seedChild = seedChildrenByID[entry.id] {
                mergedByID[entry.id] = buildNodeState(from: seedChild, overrideEntry: entry)
            } else {
                mergedByID[entry.id] = FileExplorerNodeState(
                    id: entry.id,
                    hostScope: entry.hostScope,
                    canonicalPath: entry.canonicalPath,
                    displayName: entry.displayName,
                    displayPath: entry.canonicalPath,
                    kind: entry.kind,
                    isHidden: entry.isHidden,
                    isExpanded: expandedNodeIDs.contains(entry.id),
                    isLoading: loadingNodeIDs.contains(entry.id),
                    errorMessage: errorMessagesByNodeID[entry.id],
                    isExplicitSurfaceRoot: false,
                    children: mergedChildren(for: entry.id, seedChildren: [])
                )
            }
        }

        for seedChild in seedChildren where mergedByID[seedChild.id] == nil {
            mergedByID[seedChild.id] = buildNodeState(from: seedChild)
        }

        return mergedByID.values.sorted(by: Self.nodeSortOrder)
    }

    private static func nodeSortOrder(_ lhs: FileExplorerNodeState, _ rhs: FileExplorerNodeState) -> Bool {
        let lhsPriority = sortPriority(for: lhs.kind)
        let rhsPriority = sortPriority(for: rhs.kind)
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }
        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }

    private static func sortPriority(for kind: FileExplorerEntryKind) -> Int {
        switch kind {
        case .directory:
            return 0
        case .symlink:
            return 1
        case .file:
            return 2
        }
    }

    private static func collectSeedNodes(
        from roots: [FileExplorerResolvedRoot]
    ) -> [FileExplorerNodeID: FileExplorerResolvedNode] {
        var result: [FileExplorerNodeID: FileExplorerResolvedNode] = [:]

        func visit(_ node: FileExplorerResolvedNode) {
            result[node.id] = node
            for child in node.children {
                visit(child)
            }
        }

        for root in roots {
            visit(root.node)
        }

        return result
    }

    private static func isDescendantOrSelf(canonicalPath: String, of ancestorPath: String) -> Bool {
        let nodeComponents = NSString(string: canonicalPath).pathComponents
        let ancestorComponents = NSString(string: ancestorPath).pathComponents
        guard ancestorComponents.count <= nodeComponents.count else { return false }
        return zip(ancestorComponents, nodeComponents).allSatisfy(==)
    }
}
