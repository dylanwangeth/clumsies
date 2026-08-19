import SwiftUI

struct SharedUpdateStatusPresentation {
    let symbolName: String
    let tint: Color
    let help: String

    static func resolve(
        freshness: DraftFreshness?,
        hasUpstreamResourceChanges: Bool,
        reconciliation: DraftReconciliationStatus?
    ) -> Self? {
        guard freshness == .behind else { return nil }
        if reconciliation == .conflicts {
            return .init(
                symbolName: "exclamationmark.triangle",
                tint: .orange,
                help: "Shared update has conflicts"
            )
        }
        if hasUpstreamResourceChanges {
            return .init(
                symbolName: "arrow.trianglehead.2.clockwise.rotate.90",
                tint: .secondary,
                help: "The shared version of this file has changed"
            )
        }
        return .init(
            symbolName: "arrow.trianglehead.2.clockwise.rotate.90",
            tint: .secondary,
            help: "Draft base is behind the shared version"
        )
    }
}

struct SharedUpdateIndicator: View {
    let freshness: DraftFreshness?
    let hasUpstreamResourceChanges: Bool
    let reconciliation: DraftReconciliationStatus?

    var body: some View {
        if let presentation = SharedUpdateStatusPresentation.resolve(
            freshness: freshness,
            hasUpstreamResourceChanges: hasUpstreamResourceChanges,
            reconciliation: reconciliation
        ) {
            Image(systemName: presentation.symbolName)
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(presentation.tint.opacity(0.72))
                .frame(width: 18, height: 18)
                .help(presentation.help)
                .accessibilityLabel(presentation.help)
        }
    }
}
