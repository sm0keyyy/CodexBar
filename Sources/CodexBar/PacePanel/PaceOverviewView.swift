import SwiftUI

struct PaceOverviewView: View {
    let model: PacePanelModel
    let input: PacePanelInput
    let onAction: (MenuDescriptor.MenuAction) -> Void

    var body: some View {
        Text(L("pace_every_provider"))
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
    }
}
