import SwiftUI

////////////////////
//// Window menu card shared by the centre and sidebar menus
/// Top to bottom:
///   recent apps strip (centre only)
///   workspace switch | workspace app strip
///   window list
/// Each block has the fixed height WindowMenuLayout used to size the panel.
// The only difference between the two menus is the recent strip.

struct WindowMenuView: View {
    @ObservedObject var state: WindowMenuState
    let presenter: WindowMenuPresenter
    private typealias Metrics = WindowMenuMetrics

    var body: some View {
        VStack(spacing: 0) {
            if state.isCenter {
                WindowMenuAppStrip(kind: .recent, state: state, presenter: presenter)
                    .frame(height: Metrics.recentStripHeight)
                    .padding(.bottom, Metrics.sectionSpacing)
            }
            HStack(alignment: .top, spacing: Metrics.sectionSpacing) {
                if WindowMenuLayout.showsWorkspaceSwitch(workspaceCount: state.content.workspaces.count) {
                    WindowMenuWorkspaceSwitch(state: state, presenter: presenter)
                }
                WindowMenuAppStrip(kind: .workspace, state: state, presenter: presenter)
                    .frame(height: Metrics.appStripHeight)
            }
            .frame(height: WindowMenuLayout.headerHeight(workspaceCount: state.content.workspaces.count), alignment: .top)
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 0.5)
                .frame(height: Metrics.sectionSpacing)
            WindowMenuWindowList(state: state, presenter: presenter)
                .frame(height: WindowMenuLayout.listHeight(windowCount: state.content.windows.count,
                                                           isCenter: state.isCenter, status: state.status))
        }
        .padding(Metrics.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .menuCard(cornerRadius: Metrics.cornerRadius)
        .modifier(MenuAppearModifier(presentationID: state.presentationID, edge: state.appearEdge))
        .padding(MenuShadowMargin.insets(facing: state.appearEdge))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(WindowMenuStrings.accessibilityLabel)
    }
}

//// Panel size = MenuShadowMargin.panelSize(card:facing:), so nothing here may grow on its own.
//////////////////
