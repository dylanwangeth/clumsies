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
}

enum ReviewLineDiff {
    static func make(base: String, proposed: String) -> [ReviewDiffLine] {
        let oldLines = base.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = proposed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
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
                lines.append(.init(id: lines.count, kind: .removal, text: value))
                oldIndex += 1
                continue
            }
            if let value = insertions[newIndex] {
                lines.append(.init(id: lines.count, kind: .insertion, text: value))
                newIndex += 1
                continue
            }
            if oldIndex < oldLines.count, newIndex < newLines.count {
                if oldLines[oldIndex] == newLines[newIndex] {
                    lines.append(.init(id: lines.count, kind: .context, text: oldLines[oldIndex]))
                    oldIndex += 1
                    newIndex += 1
                } else {
                    lines.append(.init(id: lines.count, kind: .removal, text: oldLines[oldIndex]))
                    lines.append(.init(id: lines.count, kind: .insertion, text: newLines[newIndex]))
                    oldIndex += 1
                    newIndex += 1
                }
            } else if oldIndex < oldLines.count {
                lines.append(.init(id: lines.count, kind: .removal, text: oldLines[oldIndex]))
                oldIndex += 1
            } else {
                lines.append(.init(id: lines.count, kind: .insertion, text: newLines[newIndex]))
                newIndex += 1
            }
        }
        return lines
    }
}

struct ReviewDiffView: View {
    let base: String
    let proposed: String

    private var lines: [ReviewDiffLine] {
        ReviewLineDiff.make(base: base, proposed: proposed)
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(prefix(for: line.kind))
                            .foregroundStyle(foreground(for: line.kind))
                            .frame(width: 22, alignment: .center)
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
            .frame(minWidth: 620, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
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
