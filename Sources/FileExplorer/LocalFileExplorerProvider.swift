import Foundation

struct LocalFileExplorerProvider: FileExplorerProvider {
    func listChildren(for request: FileExplorerListRequest) async throws -> [FileExplorerEntry] {
        guard case .local = request.hostScope else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }

        return try await Task.detached(priority: .utility) {
            let url = URL(fileURLWithPath: request.canonicalPath, isDirectory: true)
            let childURLs = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey],
                options: []
            )

            return try childURLs.map { childURL in
                let resourceValues = try childURL.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey])
                let canonicalPath = childURL.standardizedFileURL.path
                let kind: FileExplorerEntryKind
                if resourceValues.isSymbolicLink == true {
                    kind = .symlink
                } else if resourceValues.isDirectory == true {
                    kind = .directory
                } else {
                    kind = .file
                }
                return FileExplorerEntry(
                    hostScope: .local,
                    canonicalPath: canonicalPath,
                    displayName: childURL.lastPathComponent,
                    kind: kind,
                    isHidden: resourceValues.isHidden == true
                )
            }
        }.value
    }
}
