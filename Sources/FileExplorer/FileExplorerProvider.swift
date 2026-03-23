import Foundation

protocol FileExplorerProvider: Sendable {
    func listChildren(for request: FileExplorerListRequest) async throws -> [FileExplorerEntry]
}
