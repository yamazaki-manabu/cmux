import AppKit
import SwiftUI

struct FileExplorerSidebarView: View {
    let workspace: Workspace?

    @StateObject private var viewModel = FileExplorerSidebarViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
        }
        .accessibilityIdentifier("FileExplorerSidebar")
        .overlay {
            if let workspace {
                FileExplorerWorkspaceObserver(workspace: workspace) {
                    Task { await viewModel.configure(using: workspace) }
                }
            }
        }
        .task(id: workspace?.id) {
            await viewModel.configure(using: workspace)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "fileExplorer.sidebar.title", defaultValue: "Files"))
                    .font(.system(size: 13, weight: .semibold))

                Text(viewModel.hostLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("FileExplorerSidebarHostLabel")
            }

            Spacer(minLength: 0)

            Button {
                viewModel.refreshAll(using: workspace)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .safeHelp(String(localized: "fileExplorer.action.refresh", defaultValue: "Refresh"))
            .disabled(workspace == nil)
            .accessibilityIdentifier("FileExplorerSidebarRefreshButton")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.emptyState {
        case .none:
            FileExplorerOutlineView(
                treeState: viewModel.treeState,
                onToggleExpansion: { nodeID in
                    viewModel.toggleExpansion(nodeID)
                },
                onRefreshNode: { nodeID in
                    viewModel.refreshNode(nodeID)
                },
                onCopyPath: copyPath(_:),
                onOpenLocalPath: openLocalPath(_:),
                onRevealInFinder: revealInFinder(_:)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .noWorkspace:
            FileExplorerEmptyStateView(
                systemImage: "sidebar.right",
                title: String(localized: "fileExplorer.empty.noWorkspace.title", defaultValue: "No workspace selected"),
                message: String(localized: "fileExplorer.empty.noWorkspace.message", defaultValue: "Select a workspace to browse its terminal directories.")
            )

        case .noTerminalDirectories:
            FileExplorerEmptyStateView(
                systemImage: "folder",
                title: String(localized: "fileExplorer.empty.noTerminalDirectories.title", defaultValue: "No terminal directories yet"),
                message: String(localized: "fileExplorer.empty.noTerminalDirectories.message", defaultValue: "Open a terminal surface or wait for its working directory to be detected.")
            )
        }
    }

    private func copyPath(_ path: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
    }

    private func openLocalPath(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func revealInFinder(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }
}

private struct FileExplorerWorkspaceObserver: View {
    @ObservedObject var workspace: Workspace
    let onChange: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onAppear(perform: onChange)
            .onReceive(workspace.$panelDirectories) { _ in
                onChange()
            }
            .onReceive(workspace.$remoteConfiguration) { _ in
                onChange()
            }
            .onReceive(workspace.$remoteConnectionState) { _ in
                onChange()
            }
            .onReceive(workspace.$remoteDaemonStatus) { _ in
                onChange()
            }
    }
}

private struct FileExplorerEmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.system(size: 13, weight: .semibold))

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
    }
}

@MainActor
private final class FileExplorerSidebarViewModel: ObservableObject {
    enum EmptyState {
        case noWorkspace
        case noTerminalDirectories
    }

    @Published private(set) var treeState = FileExplorerTreeState(roots: [])
    @Published private(set) var hostLabel = String(localized: "fileExplorer.host.local", defaultValue: "Local")
    @Published private(set) var emptyState: EmptyState? = .noWorkspace

    private var store: FileExplorerStore?
    private var providerIdentity: ProviderIdentity?
    private var configurationGeneration: UInt64 = 0

    func configure(using workspace: Workspace?) async {
        configurationGeneration &+= 1
        let generation = configurationGeneration

        guard let workspace else {
            hostLabel = String(localized: "fileExplorer.host.local", defaultValue: "Local")
            emptyState = .noWorkspace
            store = nil
            providerIdentity = nil
            treeState = FileExplorerTreeState(roots: [])
            return
        }

        let remoteContext = workspace.fileExplorerRemoteContext()
        hostLabel = remoteContext?.configuration.displayTarget
            ?? String(localized: "fileExplorer.host.local", defaultValue: "Local")

        let roots = workspace.fileExplorerResolvedRootsInDisplayOrder()
        emptyState = roots.isEmpty ? .noTerminalDirectories : nil

        let nextProviderIdentity = providerIdentity(for: remoteContext)
        if store == nil || providerIdentity != nextProviderIdentity {
            store = FileExplorerStore(provider: makeProvider(for: remoteContext))
            providerIdentity = nextProviderIdentity
        }

        guard let store else { return }
        await store.refreshRoots(roots)
        let snapshot = await store.snapshot()
        guard generation == configurationGeneration else { return }
        treeState = snapshot
    }

    func toggleExpansion(_ nodeID: FileExplorerNodeID) {
        guard let store else { return }
        Task {
            await store.toggleExpansion(for: nodeID)
            treeState = await store.snapshot()
        }
    }

    func refreshNode(_ nodeID: FileExplorerNodeID) {
        guard let store else { return }
        Task {
            await store.refreshNode(nodeID)
            treeState = await store.snapshot()
        }
    }

    func refreshAll(using workspace: Workspace?) {
        Task {
            await configure(using: workspace)
            guard let store else { return }
            for nodeID in refreshableNodeIDs(in: treeState.roots) {
                await store.refreshNode(nodeID)
            }
            treeState = await store.snapshot()
        }
    }

    private func refreshableNodeIDs(in nodes: [FileExplorerNodeState]) -> [FileExplorerNodeID] {
        nodes.flatMap { node in
            let descendantIDs = node.isExpanded ? refreshableNodeIDs(in: node.children) : []
            return [node.id] + descendantIDs
        }
    }

    private func providerIdentity(for remoteContext: FileExplorerRemoteContext?) -> ProviderIdentity {
        guard let remoteContext else { return .local }
        return .remote(
            configuration: remoteContext.configuration,
            remotePath: remoteContext.remotePath
        )
    }

    private func makeProvider(for remoteContext: FileExplorerRemoteContext?) -> FileExplorerProvider {
        guard let remoteContext else {
            return LocalFileExplorerProvider()
        }

        guard let remotePath = remoteContext.remotePath else {
            return FileExplorerUnavailableProvider(
                message: String(
                    localized: "fileExplorer.error.waitingForRemoteDaemon",
                    defaultValue: "Waiting for the SSH file explorer to become available."
                )
            )
        }

        return RemoteFileExplorerProvider(
            configuration: remoteContext.configuration,
            remotePath: remotePath
        )
    }
}

private enum ProviderIdentity: Equatable {
    case local
    case remote(configuration: WorkspaceRemoteConfiguration, remotePath: String?)
}

private struct FileExplorerUnavailableProvider: FileExplorerProvider {
    struct UnavailableError: LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }

    let message: String

    func listChildren(for request: FileExplorerListRequest) async throws -> [FileExplorerEntry] {
        _ = request
        throw UnavailableError(message: message)
    }
}
