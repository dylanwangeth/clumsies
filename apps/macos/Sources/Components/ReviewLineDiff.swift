import SwiftUI

enum ReviewDiffLineKind: Equatable, Sendable {
    case context
    case insertion
    case removal
}

struct ReviewDiffLine: Identifiable, Sendable {
    let id: Int
    let kind: ReviewDiffLineKind
    let text: String
    let oldLineNumber: Int?
    let newLineNumber: Int?
}

enum ReviewLineDiff {
    static func make(base: String, proposed: String) -> [ReviewDiffLine] {
        let oldLines = lines(in: base)
        let newLines = lines(in: proposed)
        let difference = newLines.difference(from: oldLines)
        var removals: [Int: String] = [:]
        var insertions: [Int: String] = [:]

        for change in difference {
            switch change {
            case .remove(let offset, let element, _):
                removals[offset] = element
            case .insert(let offset, let element, _):
                insertions[offset] = element
            }
        }

        var lines: [ReviewDiffLine] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < oldLines.count || newIndex < newLines.count {
            if let value = removals[oldIndex] {
                lines.append(.init(
                    id: lines.count,
                    kind: .removal,
                    text: value,
                    oldLineNumber: oldIndex + 1,
                    newLineNumber: nil
                ))
                oldIndex += 1
                continue
            }
            if let value = insertions[newIndex] {
                lines.append(.init(
                    id: lines.count,
                    kind: .insertion,
                    text: value,
                    oldLineNumber: nil,
                    newLineNumber: newIndex + 1
                ))
                newIndex += 1
                continue
            }
            if oldIndex < oldLines.count, newIndex < newLines.count {
                if oldLines[oldIndex] == newLines[newIndex] {
                    lines.append(.init(
                        id: lines.count,
                        kind: .context,
                        text: oldLines[oldIndex],
                        oldLineNumber: oldIndex + 1,
                        newLineNumber: newIndex + 1
                    ))
                    oldIndex += 1
                    newIndex += 1
                } else {
                    lines.append(.init(
                        id: lines.count,
                        kind: .removal,
                        text: oldLines[oldIndex],
                        oldLineNumber: oldIndex + 1,
                        newLineNumber: nil
                    ))
                    lines.append(.init(
                        id: lines.count,
                        kind: .insertion,
                        text: newLines[newIndex],
                        oldLineNumber: nil,
                        newLineNumber: newIndex + 1
                    ))
                    oldIndex += 1
                    newIndex += 1
                }
            } else if oldIndex < oldLines.count {
                lines.append(.init(
                    id: lines.count,
                    kind: .removal,
                    text: oldLines[oldIndex],
                    oldLineNumber: oldIndex + 1,
                    newLineNumber: nil
                ))
                oldIndex += 1
            } else {
                lines.append(.init(
                    id: lines.count,
                    kind: .insertion,
                    text: newLines[newIndex],
                    oldLineNumber: nil,
                    newLineNumber: newIndex + 1
                ))
                newIndex += 1
            }
        }
        return lines
    }

    private static func lines(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}

struct ReviewDiffView: View {
    let base: String
    let proposed: String
    let basePath: String?
    let proposedPath: String?
    let scrollAxes: Axis.Set
    let fillsAvailableWidth: Bool

    init(
        base: String,
        proposed: String,
        basePath: String? = nil,
        proposedPath: String? = nil,
        scrollAxes: Axis.Set = .horizontal,
        fillsAvailableWidth: Bool = false
    ) {
        self.base = base
        self.proposed = proposed
        self.basePath = basePath
        self.proposedPath = proposedPath
        self.scrollAxes = scrollAxes
        self.fillsAvailableWidth = fillsAvailableWidth
    }

    private var lines: [ReviewDiffLine] {
        ReviewLineDiff.make(base: base, proposed: proposed)
    }

    private var insertionCount: Int {
        lines.count { $0.kind == .insertion }
    }

    private var removalCount: Int {
        lines.count { $0.kind == .removal }
    }

    var body: some View {
        VStack(spacing: 0) {
            if basePath != nil || proposedPath != nil {
                fileHeader
                Divider()
            }

            if lines.isEmpty {
                Text("No content changes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(20)
            } else {
                diffContent
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(.separator))
    }

    @ViewBuilder
    private var diffContent: some View {
        if fillsAvailableWidth {
            GeometryReader { proxy in
                diffScroll(
                    minWidth: max(620, proxy.size.width),
                    minHeight: proxy.size.height
                )
            }
        } else {
            diffScroll(minWidth: 620)
        }
    }

    private func diffScroll(minWidth: CGFloat, minHeight: CGFloat? = nil) -> some View {
        ScrollView(scrollAxes) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        lineNumber(line.newLineNumber ?? line.oldLineNumber)
                        Text(prefix(for: line.kind))
                            .foregroundStyle(foreground(for: line.kind))
                            .frame(width: 24, alignment: .center)
                        Text(line.text.isEmpty ? " " : line.text)
                            .textSelection(.enabled)
                    }
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                    .padding(.trailing, 10)
                    .background(background(for: line.kind))
                }
            }
            .frame(minWidth: minWidth, minHeight: minHeight, alignment: .topLeading)
        }
    }

    private var fileHeader: some View {
        HStack(spacing: 7) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)

            Text(basePath ?? "/dev/null")
                .lineLimit(1)
                .truncationMode(.middle)

            if basePath != proposedPath {
                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)
                Text(proposedPath ?? "/dev/null")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            if removalCount > 0 {
                Text("−\(removalCount)")
                    .foregroundStyle(.red)
            }
            if insertionCount > 0 {
                Text("+\(insertionCount)")
                    .foregroundStyle(.green)
            }
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    private func lineNumber(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .foregroundStyle(.tertiary)
            .frame(width: 38, alignment: .trailing)
            .padding(.trailing, 7)
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
            }
    }

    private func prefix(for kind: ReviewDiffLineKind) -> String {
        switch kind {
        case .context: " "
        case .insertion: "+"
        case .removal: "-"
        }
    }

    private func foreground(for kind: ReviewDiffLineKind) -> Color {
        switch kind {
        case .context: .secondary
        case .insertion: .green
        case .removal: .red
        }
    }

    private func background(for kind: ReviewDiffLineKind) -> Color {
        switch kind {
        case .context: .clear
        case .insertion: .green.opacity(0.12)
        case .removal: .red.opacity(0.12)
        }
    }
}
