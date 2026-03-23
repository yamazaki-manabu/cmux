import SwiftUI

final class FileExplorerSidebarState: ObservableObject {
    @Published var isVisible: Bool
    @Published var persistedWidth: CGFloat

    init(
        isVisible: Bool = false,
        persistedWidth: CGFloat = CGFloat(SessionPersistencePolicy.defaultFileExplorerWidth)
    ) {
        self.isVisible = isVisible
        let sanitized = SessionPersistencePolicy.sanitizedFileExplorerWidth(Double(persistedWidth))
        self.persistedWidth = CGFloat(sanitized)
    }

    func toggle() {
        isVisible.toggle()
    }
}
