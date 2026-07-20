import MarkdownUI
import SwiftUI

struct MarkdownPreview: View {
    let source: String

    var body: some View {
        ScrollView {
            Markdown(source)
                .markdownTheme(.gitHub)
                .textSelection(.enabled)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 36)
                .padding(.vertical, 28)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
