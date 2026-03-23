import XCTest
@testable import cmux_DEV

final class RemoteFileExplorerProviderTests: XCTestCase {
    func testRemoteProviderMapsFSListResponseIntoExplorerEntries() async throws {
        let configuration = WorkspaceRemoteConfiguration(
            destination: "devbox",
            port: 2222,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil
        )
        let hostScope = FileExplorerHostScope.ssh(
            destination: configuration.destination,
            port: configuration.port,
            identityFingerprint: configuration.proxyBrokerTransportKey
        )

        let provider = RemoteFileExplorerProvider(
            configuration: configuration,
            remotePath: "/home/dev/.cmux/bin/cmuxd-remote"
        ) { path, receivedConfiguration, remotePath in
            XCTAssertEqual(path, "/repo")
            XCTAssertEqual(receivedConfiguration, configuration)
            XCTAssertEqual(remotePath, "/home/dev/.cmux/bin/cmuxd-remote")
            return [
                .init(canonicalPath: "/repo/Sources", displayName: "Sources", kind: .directory),
                .init(canonicalPath: "/repo/.env", displayName: ".env", kind: .file),
                .init(canonicalPath: "/repo/current", displayName: "current", kind: .symlink),
            ]
        }

        let entries = try await provider.listChildren(
            for: FileExplorerListRequest(
                nodeID: .path(hostScope: hostScope, canonicalPath: "/repo")
            )
        )

        XCTAssertEqual(entries.map(\.displayName), ["Sources", ".env", "current"])
        XCTAssertEqual(entries.map(\.kind), [.directory, .file, .symlink])
        XCTAssertEqual(entries.map(\.canonicalPath), ["/repo/Sources", "/repo/.env", "/repo/current"])
        XCTAssertEqual(entries.map(\.isHidden), [false, true, false])
        XCTAssertTrue(entries.allSatisfy { $0.hostScope == hostScope })
    }

    func testRemoteProviderReturnsInlineErrorWhenDaemonPathIsMissing() async throws {
        let configuration = WorkspaceRemoteConfiguration(
            destination: "devbox",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil
        )
        let provider = RemoteFileExplorerProvider(
            configuration: configuration,
            remotePath: "/home/dev/.cmux/bin/cmuxd-remote"
        ) { _, _, _ in
            throw NSError(
                domain: "cmux.remote.daemon.rpc",
                code: 14,
                userInfo: [NSLocalizedDescriptionKey: "fs.list failed (not_found): path does not exist"]
            )
        }

        do {
            _ = try await provider.listChildren(
                for: FileExplorerListRequest(
                    nodeID: .path(
                        hostScope: .ssh(
                            destination: configuration.destination,
                            port: configuration.port,
                            identityFingerprint: configuration.proxyBrokerTransportKey
                        ),
                        canonicalPath: "/missing"
                    )
                )
            )
            XCTFail("Expected provider to throw")
        } catch {
            XCTAssertEqual(error.localizedDescription, "fs.list failed (not_found): path does not exist")
        }
    }
}
