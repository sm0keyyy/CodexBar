import SwiftUI

struct PaceProviderTabContext {
    let card: UsageMenuCardView.Model?
    let menu: MenuDescriptor
    let accountCount: Int
    let error: String?
}

struct PaceProviderTabView: View {
    let block: PaceProviderBlock
    let input: PacePanelInput
    let context: PaceProviderTabContext?
    let onAction: (MenuDescriptor.MenuAction) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(self.block.name).fontWeight(.semibold)
            if let plan = self.context?.card?.planText { Text(plan).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
            if let email = self.context?.card?.email {
                Text(email).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}
