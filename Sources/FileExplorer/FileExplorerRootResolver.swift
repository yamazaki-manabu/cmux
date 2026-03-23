import Foundation

enum FileExplorerRootResolver {
    static func resolve(
        orderedTerminalRoots: [FileExplorerRootInput],
        homeDirectoryForTildeExpansion: String?
    ) -> [FileExplorerResolvedRoot] {
        let uniqueRecords = uniqueRootRecords(
            from: orderedTerminalRoots,
            homeDirectoryForTildeExpansion: homeDirectoryForTildeExpansion
        )
        guard !uniqueRecords.isEmpty else { return [] }

        var orderedHostScopes: [FileExplorerHostScope] = []
        var recordsByHostScope: [FileExplorerHostScope: [CanonicalRootRecord]] = [:]
        for record in uniqueRecords {
            if recordsByHostScope[record.hostScope] == nil {
                orderedHostScopes.append(record.hostScope)
            }
            recordsByHostScope[record.hostScope, default: []].append(record)
        }

        return orderedHostScopes.flatMap { hostScope in
            resolveHostScope(
                hostScope,
                records: recordsByHostScope[hostScope] ?? []
            )
        }
    }

    private static func resolveHostScope(
        _ hostScope: FileExplorerHostScope,
        records: [CanonicalRootRecord]
    ) -> [FileExplorerResolvedRoot] {
        let sortedRecords = records.sorted {
            let lhsDepth = pathComponents(for: $0.canonicalPath).count
            let rhsDepth = pathComponents(for: $1.canonicalPath).count
            if lhsDepth != rhsDepth {
                return lhsDepth < rhsDepth
            }
            return $0.firstOccurrenceIndex < $1.firstOccurrenceIndex
        }

        var roots: [NodeBuilder] = []
        var buildersByCanonicalPath: [String: NodeBuilder] = [:]

        for record in sortedRecords {
            let recordComponents = pathComponents(for: record.canonicalPath)
            if let existing = buildersByCanonicalPath[record.canonicalPath] {
                existing.merge(record)
                continue
            }

            let parent = deepestAncestor(
                for: recordComponents,
                in: Array(buildersByCanonicalPath.values)
            )

            if let parent {
                var current = parent
                let parentComponents = pathComponents(for: parent.canonicalPath)
                for componentCount in (parentComponents.count + 1)...recordComponents.count {
                    let partialComponents = Array(recordComponents.prefix(componentCount))
                    let partialPath = path(from: partialComponents)
                    if let existing = buildersByCanonicalPath[partialPath] {
                        current = existing
                        if partialPath == record.canonicalPath {
                            existing.merge(record)
                        }
                        continue
                    }

                    let isExplicitRoot = partialPath == record.canonicalPath
                    let builder = NodeBuilder(
                        hostScope: hostScope,
                        canonicalPath: partialPath,
                        displayPath: isExplicitRoot ? record.displayPath : partialPath,
                        name: nodeName(displayPath: isExplicitRoot ? record.displayPath : partialPath, canonicalPath: partialPath),
                        referencedPanelIDs: isExplicitRoot ? record.referencedPanelIDs : [],
                        firstOccurrenceIndex: record.firstOccurrenceIndex
                    )
                    current.appendChild(builder)
                    buildersByCanonicalPath[partialPath] = builder
                    current = builder
                }
            } else {
                let builder = NodeBuilder(
                    hostScope: hostScope,
                    canonicalPath: record.canonicalPath,
                    displayPath: record.displayPath,
                    name: nodeName(displayPath: record.displayPath, canonicalPath: record.canonicalPath),
                    referencedPanelIDs: record.referencedPanelIDs,
                    firstOccurrenceIndex: record.firstOccurrenceIndex
                )
                roots.append(builder)
                buildersByCanonicalPath[record.canonicalPath] = builder
            }
        }

        return roots.map { FileExplorerResolvedRoot(node: $0.build()) }
    }

    private static func uniqueRootRecords(
        from orderedTerminalRoots: [FileExplorerRootInput],
        homeDirectoryForTildeExpansion: String?
    ) -> [CanonicalRootRecord] {
        var orderedKeys: [RootKey] = []
        var recordsByKey: [RootKey: CanonicalRootRecord] = [:]

        for (index, input) in orderedTerminalRoots.enumerated() {
            let trimmedDirectory = input.rawDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedDirectory.isEmpty,
                  let canonicalPath = SidebarBranchOrdering.canonicalDirectoryKey(
                      trimmedDirectory,
                      homeDirectoryForTildeExpansion: homeDirectoryForTildeExpansion
                  ) else { continue }

            let key = RootKey(hostScope: input.hostScope, canonicalPath: canonicalPath)
            if var existing = recordsByKey[key] {
                if !existing.referencedPanelIDs.contains(input.panelID) {
                    existing.referencedPanelIDs.append(input.panelID)
                }
                recordsByKey[key] = existing
                continue
            }

            orderedKeys.append(key)
            recordsByKey[key] = CanonicalRootRecord(
                hostScope: input.hostScope,
                canonicalPath: canonicalPath,
                displayPath: trimmedDirectory,
                referencedPanelIDs: [input.panelID],
                firstOccurrenceIndex: index
            )
        }

        return orderedKeys.compactMap { recordsByKey[$0] }
    }

    private static func deepestAncestor(
        for targetComponents: [String],
        in builders: [NodeBuilder]
    ) -> NodeBuilder? {
        builders
            .filter { builder in
                let candidateComponents = pathComponents(for: builder.canonicalPath)
                return candidateComponents.count < targetComponents.count
                    && isPrefix(candidateComponents, of: targetComponents)
            }
            .max { lhs, rhs in
                pathComponents(for: lhs.canonicalPath).count < pathComponents(for: rhs.canonicalPath).count
            }
    }

    private static func isPrefix(_ prefix: [String], of target: [String]) -> Bool {
        guard prefix.count <= target.count else { return false }
        return zip(prefix, target).allSatisfy(==)
    }

    private static func pathComponents(for canonicalPath: String) -> [String] {
        NSString(string: canonicalPath).pathComponents
    }

    private static func path(from components: [String]) -> String {
        guard !components.isEmpty else { return "/" }
        return NSString.path(withComponents: components)
    }

    private static func nodeName(displayPath: String, canonicalPath: String) -> String {
        let trimmedDisplayPath = displayPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedDisplayPath == "~" || trimmedDisplayPath == "/" {
            return trimmedDisplayPath
        }

        let displayName = NSString(string: trimmedDisplayPath).lastPathComponent
        if !displayName.isEmpty && displayName != "/" {
            return displayName
        }

        let canonicalName = NSString(string: canonicalPath).lastPathComponent
        if !canonicalName.isEmpty && canonicalName != "/" {
            return canonicalName
        }

        return canonicalPath
    }
}

private struct RootKey: Hashable {
    let hostScope: FileExplorerHostScope
    let canonicalPath: String
}

private struct CanonicalRootRecord {
    let hostScope: FileExplorerHostScope
    let canonicalPath: String
    let displayPath: String
    var referencedPanelIDs: [UUID]
    let firstOccurrenceIndex: Int
}

private final class NodeBuilder {
    let hostScope: FileExplorerHostScope
    let canonicalPath: String
    let firstOccurrenceIndex: Int
    var displayPath: String
    var name: String
    var referencedPanelIDs: [UUID]

    private var childOrder: [String] = []
    private var childrenByCanonicalPath: [String: NodeBuilder] = [:]

    init(
        hostScope: FileExplorerHostScope,
        canonicalPath: String,
        displayPath: String,
        name: String,
        referencedPanelIDs: [UUID],
        firstOccurrenceIndex: Int
    ) {
        self.hostScope = hostScope
        self.canonicalPath = canonicalPath
        self.displayPath = displayPath
        self.name = name
        self.referencedPanelIDs = referencedPanelIDs
        self.firstOccurrenceIndex = firstOccurrenceIndex
    }

    func appendChild(_ child: NodeBuilder) {
        if childrenByCanonicalPath[child.canonicalPath] == nil {
            childOrder.append(child.canonicalPath)
        }
        childrenByCanonicalPath[child.canonicalPath] = child
    }

    func merge(_ record: CanonicalRootRecord) {
        for panelID in record.referencedPanelIDs where !referencedPanelIDs.contains(panelID) {
            referencedPanelIDs.append(panelID)
        }
    }

    func build() -> FileExplorerResolvedNode {
        FileExplorerResolvedNode(
            id: .path(hostScope: hostScope, canonicalPath: canonicalPath),
            hostScope: hostScope,
            canonicalPath: canonicalPath,
            displayPath: displayPath,
            name: name,
            referencedPanelIDs: referencedPanelIDs,
            children: childOrder.compactMap { childrenByCanonicalPath[$0]?.build() }
        )
    }
}
