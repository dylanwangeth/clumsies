import SwiftUI

struct UnifiedDiffView: View {
    let model: SplitDiffModel
    let commentsByLine: [Int: [ReviewComment]]
    let composingLine: Int?
    let commentDraft: String
    let isSubmittingComment: Bool
    let onCommentDraftChange: (String) -> Void
    let onRequestComment: (Int) -> Void
    let onCancelComment: () -> Void
    let onSubmitComment: (Int) -> Void
    let onReply: (Int) -> Void

    @State private var hoveredLine: Int?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.blocks) { block in
                    blockHeader(block)
                    ForEach(block.rows) { row in
                        diffRow(row)
                        if let line = newLineNumber(of: row),
                           let thread = commentsByLine[line] {
                            commentThread(thread, line: line)
                        }
                        if composingLine == newLineNumber(of: row) {
                            composer(for: newLineNumber(of: row) ?? 0)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func blockHeader(_ block: SplitDiffBlock) -> some View {
        Group {
            switch block.kind {
            case .hunk(let label):
                Text(label)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary.opacity(0.5))
            case .omission:
                Text("…")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
            }
        }
    }

    private func diffRow(_ row: SplitDiffRow) -> some View {
        let cell: (kind: SplitDiffCellKind, text: String, line: Int)? = diffCell(of: row)
        guard let cell else { return AnyView(EmptyView()) }
        let line = newLineNumber(of: row)
        let isHovered = line != nil && hoveredLine == line
        return AnyView(
            HStack(spacing: 0) {
                Text(cell.kind == .removal ? "-" : (cell.kind == .insertion ? "+" : " "))
                    .font(.caption.monospaced())
                    .foregroundStyle(
                        cell.kind == .removal ? Color.red : (cell.kind == .insertion ? Color.green : Color.secondary)
                    )
                    .frame(width: 14)
                Text("\(cell.line)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .frame(width: 40, alignment: .trailing)
                Text(cell.text)
                    .font(.caption.monospaced())
                    .foregroundStyle(cell.kind == .removal ? Color.red : (cell.kind == .insertion ? Color.green : Color.primary))
                    .textSelection(.enabled)
                    .padding(.leading, 10)
                Spacer(minLength: 0)
                if isHovered {
                    Button {
                        if let line { onRequestComment(line) }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .help("Comment on this line")
                    .accessibilityLabel("Comment on line \(cell.line)")
                    .padding(.trailing, 6)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .background(cell.kind == .removal ? Color.red.opacity(0.07) : (cell.kind == .insertion ? Color.green.opacity(0.07) : .clear))
            .onHover { hovering in
                hoveredLine = hovering ? (line ?? hoveredLine) : nil
            }
        )
    }

    private func commentThread(_ comments: [ReviewComment], line: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(comments) { comment in
                ReviewCommentRow(comment: comment) {
                    onReply(line)
                }
            }
        }
        .padding(.leading, 76)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func composer(for line: Int) -> some View {
        ReviewCommentComposer(
            text: commentDraft,
            isSubmitting: isSubmittingComment,
            onTextChange: onCommentDraftChange,
            onCancel: onCancelComment,
            onSubmit: { onSubmitComment(line) }
        )
        .padding(.leading, 76)
        .padding(.vertical, 6)
    }

    private func diffCell(of row: SplitDiffRow) -> (kind: SplitDiffCellKind, text: String, line: Int)? {
        if let original = row.original, original.kind == .removal {
            return (kind: .removal, text: original.text, line: original.lineNumber)
        }
        if let modified = row.modified, modified.kind == .insertion {
            return (kind: .insertion, text: modified.text, line: modified.lineNumber)
        }
        if let modified = row.modified {
            return (kind: .context, text: modified.text, line: modified.lineNumber)
        }
        return nil
    }

    private func newLineNumber(of row: SplitDiffRow) -> Int? {
        row.modified?.lineNumber
    }
}
