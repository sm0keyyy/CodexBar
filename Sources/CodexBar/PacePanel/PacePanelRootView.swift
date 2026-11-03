import CodexBarCore
import SwiftUI

enum PacePanelTab: Equatable {
    case overview
    case provider(UsageProvider)

    static func resolve(
        providers: [UsageProvider], lastSelectedWasOverview: Bool, selectedProvider: UsageProvider?) -> Self
    {
        guard !lastSelectedWasOverview, let selectedProvider, providers.contains(selectedProvider) else {
            return .overview
        }
        return .provider(selectedProvider)
    }

    var provider: UsageProvider? {
        if case let .provider(provider) = self { return provider }
        return nil
    }
}

struct PacePanelRootView: View {
    let input: PacePanelInput
    let model: PacePanelModel
    let selection: PacePanelTab
    let providerContext: PaceProviderTabContext?
    let onCommand: (PacePanelCommand) -> Void
    let onAction: (MenuDescriptor.MenuAction) -> Void
    var onFix: (UsageProvider, GroupedPillState.Fix) -> Void = { _, _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        self.tab(L("Overview"), index: 0, provider: nil)
                        ForEach(Array(self.model.providers.enumerated()), id: \.element.provider) { index, block in
                            self.tab(block.name, index: index + 1, provider: block.provider)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                }
                .onAppear { proxy.scrollTo(self.selectedIndex, anchor: .center) }
                .onChange(of: self.selection) { _, _ in proxy.scrollTo(self.selectedIndex, anchor: .center) }
            }
            switch self.selection {
            case .overview:
                PaceOverviewView(model: self.model, input: self.input, onAction: self.onAction, onFix: self.onFix)
            case let .provider(provider):
                if let block = self.model.providers.first(where: { $0.provider == provider }) {
                    PaceProviderTabView(
                        block: block, input: self.input, context: self.providerContext, onAction: self.onAction)
                }
            }
            Divider().padding(.top, 6)
            PaceFooter(onAction: self.onAction)
        }
        .frame(width: 360)
        .font(.system(size: 13))
        .transaction { $0.animation = nil }
        .codexBarLocalized()
    }

    private var selectedIndex: Int {
        guard let provider = self.selection.provider else { return 0 }
        return self.model.providers.firstIndex(where: { $0.provider == provider }).map { $0 + 1 } ?? 0
    }

    private func tab(_ title: String, index: Int, provider: UsageProvider?) -> some View {
        let isSelected = self.selectedIndex == index
        return Button { self.onCommand(.selectTab(index)) } label: {
            HStack(spacing: 6) {
                if let provider {
                    Circle().fill(PacePalette.colors(for: provider).fill).frame(width: 7, height: 7)
                }
                Text(title)
            }
            .font(.system(size: 12))
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(isSelected ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(isSelected ? 0.09 : 0), lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .id(index)
    }
}
