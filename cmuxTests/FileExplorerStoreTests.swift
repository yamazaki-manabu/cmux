import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class FileExplorerStoreTests: XCTestCase {
    func testLoadingChildrenSortsDirectoriesBeforeFiles() async throws {
        let tempDirectory = try makeTemporaryDirectory()
        let sourcesDirectory = tempDirectory.appendingPathComponent("Sources", isDirectory: true)
        let readmeFile = tempDirectory.appendingPathComponent("README.md")

        try FileManager.default.createDirectory(at: sourcesDirectory, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: readmeFile)

        let root = makeRoot(canonicalPath: tempDirectory.path, displayPath: tempDirectory.path)
        let store = FileExplorerStore(provider: LocalFileExplorerProvider())

        await store.refreshRoots([root])
        await store.toggleExpansion(for: root.id)

        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.roots.first?.children.map(\.displayName), ["Sources", "README.md"])
    }

    func testProviderErrorsBecomeNodeErrorsWithoutDroppingSiblingState() async throws {
        let rootPath = "/tmp/project"
        let cachedPath = rootPath + "/cached"
        let brokenPath = rootPath + "/broken"
        let cachedFilePath = cachedPath + "/README.md"

        let root = makeRoot(
            canonicalPath: rootPath,
            displayPath: rootPath,
            children: [
                makeNode(canonicalPath: cachedPath, displayPath: cachedPath),
                makeNode(canonicalPath: brokenPath, displayPath: brokenPath),
            ]
        )

        let provider = FakeFileExplorerProvider(
            responses: [
                .path(hostScope: .local, canonicalPath: rootPath): .success([
                    FileExplorerEntry(
                        hostScope: .local,
                        canonicalPath: cachedPath,
                        displayName: "cached",
                        kind: .directory,
                        isHidden: false
                    ),
                    FileExplorerEntry(
                        hostScope: .local,
                        canonicalPath: brokenPath,
                        displayName: "broken",
                        kind: .directory,
                        isHidden: false
                    ),
                ]),
                .path(hostScope: .local, canonicalPath: cachedPath): .success([
                    FileExplorerEntry(
                        hostScope: .local,
                        canonicalPath: cachedFilePath,
                        displayName: "README.md",
                        kind: .file,
                        isHidden: false
                    ),
                ]),
                .path(hostScope: .local, canonicalPath: brokenPath): .failure(FakeProviderError.accessDenied),
            ]
        )

        let store = FileExplorerStore(provider: provider)
        await store.refreshRoots([root])
        await store.toggleExpansion(for: root.id)
        await store.toggleExpansion(for: .path(hostScope: .local, canonicalPath: cachedPath))
        await store.toggleExpansion(for: .path(hostScope: .local, canonicalPath: brokenPath))

        let snapshot = await store.snapshot()
        let rootNode = try XCTUnwrap(snapshot.roots.first)
        let cachedNode = try XCTUnwrap(rootNode.children.first(where: { $0.displayName == "cached" }))
        let brokenNode = try XCTUnwrap(rootNode.children.first(where: { $0.displayName == "broken" }))

        XCTAssertEqual(cachedNode.children.map(\.displayName), ["README.md"])
        XCTAssertEqual(brokenNode.errorMessage, FakeProviderError.accessDenied.localizedDescription)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-file-explorer-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeRoot(
        canonicalPath: String,
        displayPath: String,
        children: [FileExplorerResolvedNode] = []
    ) -> FileExplorerResolvedRoot {
        FileExplorerResolvedRoot(
            node: makeNode(
                canonicalPath: canonicalPath,
                displayPath: displayPath,
                children: children
            )
        )
    }

    private func makeNode(
        canonicalPath: String,
        displayPath: String,
        children: [FileExplorerResolvedNode] = []
    ) -> FileExplorerResolvedNode {
        FileExplorerResolvedNode(
            id: .path(hostScope: .local, canonicalPath: canonicalPath),
            hostScope: .local,
            canonicalPath: canonicalPath,
            displayPath: displayPath,
            name: URL(fileURLWithPath: canonicalPath).lastPathComponent,
            referencedPanelIDs: [],
            children: children
        )
    }
}

private actor FakeFileExplorerProvider: FileExplorerProvider {
    enum Response {
        case success([FileExplorerEntry])
        case failure(Error)
    }

    private let responses: [FileExplorerNodeID: Response]

    init(responses: [FileExplorerNodeID: Response]) {
        self.responses = responses
    }

    func listChildren(for request: FileExplorerListRequest) async throws -> [FileExplorerEntry] {
        guard let response = responses[request.nodeID] else { return [] }
        switch response {
        case .success(let entries):
            return entries
        case .failure(let error):
            throw error
        }
    }
}

private enum FakeProviderError: LocalizedError {
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Access denied"
        }
    }
}
