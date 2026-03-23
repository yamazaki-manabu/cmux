import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class FileExplorerRootResolverTests: XCTestCase {
    func testNestedLocalRootsCollapseIntoSingleForest() {
        let firstPanelID = UUID()
        let secondPanelID = UUID()

        let roots = FileExplorerRootResolver.resolve(
            orderedTerminalRoots: [
                .local(panelID: firstPanelID, directory: "~/fun"),
                .local(panelID: secondPanelID, directory: "~/fun/a"),
            ],
            homeDirectoryForTildeExpansion: "/Users/lawrence"
        )

        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots[0].displayPath, "~/fun")
        XCTAssertEqual(roots[0].referencedPanelIDs, [firstPanelID])
        XCTAssertTrue(roots[0].containsReferencedDescendant("~/fun/a"))
    }

    func testSamePathStringDoesNotMergeAcrossLocalAndSSHScopes() {
        let roots = FileExplorerRootResolver.resolve(
            orderedTerminalRoots: [
                .local(panelID: UUID(), directory: "/tmp/project"),
                .ssh(panelID: UUID(), destination: "devbox", port: 22, directory: "/tmp/project"),
            ],
            homeDirectoryForTildeExpansion: nil
        )

        XCTAssertEqual(roots.count, 2)
        XCTAssertNotEqual(roots[0].hostScope, roots[1].hostScope)
    }

    func testSameCanonicalPathMergesPanelReferencesWithinHostScope() {
        let firstPanelID = UUID()
        let secondPanelID = UUID()

        let roots = FileExplorerRootResolver.resolve(
            orderedTerminalRoots: [
                .local(panelID: firstPanelID, directory: "/Users/lawrence/fun"),
                .local(panelID: secondPanelID, directory: "~/fun"),
            ],
            homeDirectoryForTildeExpansion: "/Users/lawrence"
        )

        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots[0].displayPath, "/Users/lawrence/fun")
        XCTAssertEqual(roots[0].referencedPanelIDs, [firstPanelID, secondPanelID])
    }
}
