import SwiftUI

struct ToolbarFilterMenu<MenuContent: View>: View {
    let selectionTitle: String
    let isLoading: Bool

    private let menuContent: () -> MenuContent

    init(
        selectionTitle: String,
        isLoading: Bool = false,
        @ViewBuilder menuContent: @escaping () -> MenuContent
    ) {
        self.selectionTitle = selectionTitle
        self.isLoading = isLoading
        self.menuContent = menuContent
    }

    var body: some View {
        Menu {
            menuContent()
        } label: {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "line.3.horizontal.decrease")
                }

                Text(selectionTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 180, alignment: .leading)
            }
        }
        .frame(maxWidth: 220, alignment: .leading)
    }
}
