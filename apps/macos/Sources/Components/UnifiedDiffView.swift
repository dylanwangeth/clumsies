import SwiftUI

enum UnifiedDiffLineKind: Equatable, Sendable {
    case context
    case insertion
    case removal
}

struct UnifiedDiffLine: Identifiable, Equatable, Sendable {
    let id: String
    let kind: UnifiedDiffLineKind
    let text: String
    let oldLineNumber: Int?
    let newLineNumber: Int?

    var commentAnchorLine: Int? {
        kind == .removal ? nil : newLineNumber
    }
}

struct UnifiedDiffBlockPresentation: Identifiable, Equatable, Sendable {
    let id: Int
    let kind: SplitDiffBlockKind
    let lines: [UnifiedDiffLine]
}

struct UnifiedDiffPresentation: Equatable, Sendable {
    let blocks: [UnifiedDiffBlockPresentation]

    init(model: SplitDiffModel, anchoredLines: Set<Int> = []) {
        if model.blocks.isEmpty, !anchoredLines.isEmpty {
            blocks = Self.anchoredContextBlocks(
                rows: model.rows,
                anchoredLines: anchoredLines,
                startingBlockId: 0
            )
            return
        }

        var presentations: [UnifiedDiffBlockPresentation] = []
        for block in model.blocks {
            if case .omission = block.kind,
               block.rows.contains(where: { row in
                   guard let line = row.modified?.lineNumber else { return false }
                   return anchoredLines.contains(line)
               }) {
                presentations.append(contentsOf: Self.anchoredContextBlocks(
                    rows: block.rows,
                    anchoredLines: anchoredLines,
                    startingBlockId: presentations.count
                ))
                continue
            }

            let id = presentations.count
            presentations.append(UnifiedDiffBlockPresentation(
                id: id,
                kind: block.kind,
                lines: Self.lines(for: block.rows, blockId: id)
            ))
        }
        blocks = presentations
    }

    var changedLineCount: Int {
        blocks.reduce(into: 0) { count, block in
            guard case .hunk = block.kind else { return }
            count += block.lines.count
        }
    }

    private static func lines(
        for rows: [SplitDiffRow],
        blockId: Int
    ) -> [UnifiedDiffLine] {
        rows.flatMap { row in
            var lines: [UnifiedDiffLine] = []

            if let original = row.original, original.kind == .removal {
                lines.append(UnifiedDiffLine(
                    id: "\(blockId)-\(row.id)-removal",
                    kind: .removal,
                    text: original.text,
                    oldLineNumber: original.lineNumber,
                    newLineNumber: nil
                ))
            }

            if let modified = row.modified, modified.kind == .insertion {
                lines.append(UnifiedDiffLine(
                    id: "\(blockId)-\(row.id)-insertion",
                    kind: .insertion,
                    text: modified.text,
                    oldLineNumber: nil,
                    newLineNumber: modified.lineNumber
                ))
            } else if let modified = row.modified {
                lines.append(UnifiedDiffLine(
                    id: "\(blockId)-\(row.id)-context",
                    kind: .context,
                    text: modified.text,
                    oldLineNumber: row.original?.lineNumber,
                    newLineNumber: modified.lineNumber
                ))
            }

            return lines
        }
    }

    private static func anchoredContextBlocks(
        rows: [SplitDiffRow],
        anchoredLines: Set<Int>,
        startingBlockId: Int,
        contextLineCount: Int = 3
    ) -> [UnifiedDiffBlockPresentation] {
        let anchorIndices = rows.indices.filter { index in
            guard let line = rows[index].modified?.lineNumber else { return false }
            return anchoredLines.contains(line)
        }
        guard !anchorIndices.isEmpty else { return [] }

        var ranges: [ClosedRange<Int>] = []
        for index in anchorIndices {
            let candidate = max(0, index - contextLineCount)
                ... min(rows.count - 1, index + contextLineCount)
            if let previous = ranges.last,
               candidate.lowerBound <= previous.upperBound + 1 {
                ranges[ranges.count - 1] = previous.lowerBound
                    ... max(previous.upperBound, candidate.upperBound)
            } else {
                ranges.append(candidate)
            }
        }

        var result: [UnifiedDiffBlockPresentation] = []
        var cursor = 0
        for range in ranges {
            if cursor < range.lowerBound {
                appendBlock(
                    kind: .omission,
                    rows: Array(rows[cursor..<range.lowerBound]),
                    startingBlockId: startingBlockId,
                    to: &result
                )
            }

            let hunkRows = Array(rows[range])
            appendBlock(
                kind: .hunk(hunkLabel(for: hunkRows)),
                rows: hunkRows,
                startingBlockId: startingBlockId,
                to: &result
            )
            cursor = range.upperBound + 1
        }

        if cursor < rows.count {
            appendBlock(
                kind: .omission,
                rows: Array(rows[cursor...]),
                startingBlockId: startingBlockId,
                to: &result
            )
        }
        return result
    }

    private static func appendBlock(
        kind: SplitDiffBlockKind,
        rows: [SplitDiffRow],
        startingBlockId: Int,
        to blocks: inout [UnifiedDiffBlockPresentation]
    ) {
        let id = startingBlockId + blocks.count
        blocks.append(.init(
            id: id,
            kind: kind,
            lines: lines(for: rows, blockId: id)
        ))
    }

    private static func hunkLabel(for rows: [SplitDiffRow]) -> String {
        let oldStart = rows.first?.original?.lineNumber ?? rows.first?.modified?.lineNumber ?? 1
        let newStart = rows.first?.modified?.lineNumber ?? rows.first?.original?.lineNumber ?? 1
        let oldCount = rows.filter { $0.original != nil }.count
        let newCount = rows.filter { $0.modified != nil }.count
        return "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
    }
}

private enum UnifiedDiffMetrics {
    static let oldLineGutterWidth: CGFloat = 42
    static let newLineGutterWidth: CGFloat = 42
    static let markerWidth: CGFloat = 18
    static let commentButtonWidth: CGFloat = 26
}

private struct UnifiedDiffViewportWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct UnifiedDiffView: View {
    let presentation: UnifiedDiffPresentation
    let commentsByLine: [Int: [ReviewComment]]
    let composingLine: Int?
    @Binding var commentDraft: String
    let isSubmittingComment: Bool
    let onRequestComment: (Int) -> Void
    let onCancelComment: () -> Void
    let onSubmitComment: (Int) -> Void
    let onReply: (Int) -> Void

    @State private var hoveredLineId: String?
    @State private var expandedOmissionIds: Set<Int> = []
    @State private var viewportWidth: CGFloat = 0

    init(
        model: SplitDiffModel,
        commentsByLine: [Int: [ReviewComment]],
        composingLine: Int?,
        commentDraft: Binding<String>,
        isSubmittingComment: Bool,
        onRequestComment: @escaping (Int) -> Void,
        onCancelComment: @escaping () -> Void,
        onSubmitComment: @escaping (Int) -> Void,
        onReply: @escaping (Int) -> Void
    ) {
        var anchoredLines = Set(commentsByLine.keys)
        if let composingLine {
            anchoredLines.insert(composingLine)
        }
        presentation = UnifiedDiffPresentation(
            model: model,
            anchoredLines: anchoredLines
        )
        self.commentsByLine = commentsByLine
        self.composingLine = composingLine
        _commentDraft = commentDraft
        self.isSubmittingComment = isSubmittingComment
        self.onRequestComment = onRequestComment
        self.onCancelComment = onCancelComment
        self.onSubmitComment = onSubmitComment
        self.onReply = onReply
    }

    var body: some View {
        Group {
            if presentation.changedLineCount == 0 {
                Text("No content changes")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 96)
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(presentation.blocks) { block in
                            blockView(block)
                        }
                    }
                    .frame(minWidth: minimumContentWidth, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: UnifiedDiffViewportWidthKey.self,
                    value: proxy.size.width
                )
            }
        }
        .onPreferenceChange(UnifiedDiffViewportWidthKey.self) { viewportWidth = $0 }
    }

    private var minimumContentWidth: CGFloat {
        max(viewportWidth, 1)
    }

    @ViewBuilder
    private func blockView(_ block: UnifiedDiffBlockPresentation) -> some View {
        switch block.kind {
        case .hunk(let label):
            hunkHeader(label)
            ForEach(block.lines) { line in
                lineView(line)
            }
        case .omission:
            omissionControl(block)
            if omissionIsExpanded(block) {
                ForEach(block.lines) { line in
                    lineView(line)
                }
            }
        }
    }

    private func hunkHeader(_ label: String) -> some View {
        Text(label)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(
                minWidth: minimumContentWidth,
                maxWidth: .infinity,
                minHeight: 26,
                alignment: .leading
            )
            .background(Color.accentColor.opacity(0.06))
    }

    private func omissionControl(_ block: UnifiedDiffBlockPresentation) -> some View {
        Button {
            if expandedOmissionIds.contains(block.id) {
                expandedOmissionIds.remove(block.id)
            } else {
                expandedOmissionIds.insert(block.id)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: omissionIsExpanded(block) ? "chevron.up" : "chevron.down")
                Text("\(block.lines.count) unchanged lines")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(
                minWidth: minimumContentWidth,
                maxWidth: .infinity,
                minHeight: 26,
                alignment: .leading
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityLabel(
            omissionIsExpanded(block)
                ? "Collapse \(block.lines.count) unchanged lines"
                : "Expand \(block.lines.count) unchanged lines"
        )
    }

    private func omissionIsExpanded(_ block: UnifiedDiffBlockPresentation) -> Bool {
        if expandedOmissionIds.contains(block.id) {
            return true
        }
        return block.lines.contains { line in
            guard let anchor = line.commentAnchorLine else { return false }
            return commentsByLine[anchor] != nil || composingLine == anchor
        }
    }

    @ViewBuilder
    private func lineView(_ line: UnifiedDiffLine) -> some View {
        diffRow(line)
        if let anchor = line.commentAnchorLine,
           let thread = commentsByLine[anchor] {
            commentThread(thread, line: anchor)
        }
        if composingLine == line.commentAnchorLine,
           let anchor = line.commentAnchorLine {
            composer(for: anchor)
        }
    }

    private func diffRow(_ line: UnifiedDiffLine) -> some View {
        HStack(alignment: .top, spacing: 0) {
            lineNumber(line.oldLineNumber, width: UnifiedDiffMetrics.oldLineGutterWidth)
            lineNumber(line.newLineNumber, width: UnifiedDiffMetrics.newLineGutterWidth)

            Text(marker(for: line.kind))
                .foregroundStyle(markerColor(for: line.kind))
                .frame(width: UnifiedDiffMetrics.markerWidth)

            commentControl(for: line)

            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.trailing, 12)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 3)
        .frame(
            minWidth: minimumContentWidth,
            maxWidth: .infinity,
            minHeight: 24,
            alignment: .topLeading
        )
        .background(rowBackground(for: line.kind))
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredLineId = hovering ? line.id : (hoveredLineId == line.id ? nil : hoveredLineId)
        }
    }

    private func lineNumber(_ value: Int?, width: CGFloat) -> some View {
        Text(value.map(String.init) ?? "")
            .foregroundStyle(.tertiary)
            .frame(width: width, alignment: .trailing)
            .padding(.trailing, 7)
            .frame(maxHeight: .infinity, alignment: .topTrailing)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.48))
    }

    @ViewBuilder
    private func commentControl(for line: UnifiedDiffLine) -> some View {
        if let anchor = line.commentAnchorLine {
            Button {
                onRequestComment(anchor)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .opacity(hoveredLineId == line.id ? 1 : 0)
            .frame(width: UnifiedDiffMetrics.commentButtonWidth)
            .help("Comment on new line \(anchor)")
            .accessibilityLabel("Comment on new line \(anchor)")
        } else {
            Color.clear
                .frame(width: UnifiedDiffMetrics.commentButtonWidth, height: 1)
                .accessibilityHidden(true)
        }
    }

    private func commentThread(_ comments: [ReviewComment], line: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(comments) { comment in
                ReviewCommentRow(comment: comment) {
                    onReply(line)
                }
            }
        }
        .padding(.leading, 112)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .frame(
            minWidth: minimumContentWidth,
            maxWidth: .infinity,
            alignment: .leading
        )
        .background(Color.accentColor.opacity(0.035))
    }

    private func composer(for line: Int) -> some View {
        ReviewCommentComposer(
            text: $commentDraft,
            isSubmitting: isSubmittingComment,
            onCancel: onCancelComment,
            onSubmit: { onSubmitComment(line) }
        )
        .padding(.leading, 112)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .frame(
            minWidth: minimumContentWidth,
            maxWidth: .infinity,
            alignment: .leading
        )
        .background(Color.accentColor.opacity(0.035))
    }

    private func marker(for kind: UnifiedDiffLineKind) -> String {
        switch kind {
        case .context: " "
        case .insertion: "+"
        case .removal: "−"
        }
    }

    private func markerColor(for kind: UnifiedDiffLineKind) -> Color {
        switch kind {
        case .context: .secondary
        case .insertion: .green
        case .removal: .red
        }
    }

    private func rowBackground(for kind: UnifiedDiffLineKind) -> Color {
        switch kind {
        case .context: .clear
        case .insertion: .green.opacity(0.08)
        case .removal: .red.opacity(0.08)
        }
    }
}
