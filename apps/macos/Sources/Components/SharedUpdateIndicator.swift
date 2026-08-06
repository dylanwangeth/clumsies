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
        guard freshness == .behind, hasUpstreamResourceChanges else { return nil }
        if reconciliation == .conflicts {
            return .init(
                symbolName: "exclamationmark.triangle",
                tint: .orange,
                help: "Shared update has conflicts"
            )
        }
        return .init(
            symbolName: "arrow.trianglehead.2.clockwise.rotate.90",
            tint: .secondary,
            help: "The shared version of this file has changed"
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

struct DraftBaseBehindIndicator: View {
    var reconciliation: DraftReconciliationStatus?

    init(reconciliation: DraftReconciliationStatus? = nil) {
        self.reconciliation = reconciliation
    }

    var body: some View {
        Image(systemName: reconciliation == .conflicts
            ? "exclamationmark.triangle"
            : "arrow.trianglehead.2.clockwise.rotate.90")
            .font(.system(size: 10, weight: .regular))
            .foregroundStyle(reconciliation == .conflicts
                ? Color.orange.opacity(0.72)
                : Color.secondary.opacity(0.72))
            .frame(width: 18, height: 18)
            .help(help)
            .accessibilityLabel(help)
    }

    private var help: String {
        reconciliation == .conflicts
            ? "Draft update has conflicts"
            : "Draft base is behind the shared version"
    }
}
