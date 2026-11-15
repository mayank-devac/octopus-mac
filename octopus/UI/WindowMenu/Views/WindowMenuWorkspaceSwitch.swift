import SwiftUI

////////////////////
//// Vertical workspace switch ("1", "2", …) beside the app strip
/// Choosing a workspace changes what this menu shows; it does not change the
// active Octopus profile. The selected pill slides between numbers.

struct WindowMenuWorkspaceSwitch: View {
    @ObservedObject var state: WindowMenuState
    let presenter: WindowMenuPresenter
    @Namespace private var selectionSpace
    private typealias Metrics = WindowMenuMetrics

    var body: some View {
        VStack(spacing: 0) {
            ForEach(state.content.workspaces) { workspace in
                item(workspace)
            }
        }
        .padding(Metrics.workspacePadding)
        .frame(width: Metrics.workspaceWidth)
        .background {
            RoundedRectangle(cornerRadius: Metrics.workspaceWidth / 2, style: .continuous)
                .strokeBorder(MenuPalette.cardStroke, lineWidth: 1)
        }
        .animation(MenuMotion.highlight, value: state.content.selectedWorkspaceID)
    }

    private func item(_ workspace: WindowMenuWorkspace) -> some View {
        let target = WindowMenuTarget.workspace(workspace.id)
        let isSelected = workspace.id == state.content.selectedWorkspaceID
        let isActive = state.focus == target || state.hovered == target
        return Button { presenter.activate(target) } label: {
            Text(workspace.label)
                .font(.system(size: 11, weight: isSelected ? .bold : .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .frame(width: Metrics.workspaceWidth - Metrics.workspacePadding * 2, height: Metrics.workspaceItemHeight)
                .background {
                    if isSelected {
                        Capsule().fill(Color.accentColor).matchedGeometryEffect(id: "selected", in: selectionSpace)
                    } else if isActive {
                        Capsule().fill(MenuPalette.hoverFill)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(MenuPressButtonStyle())
        .focusEffectDisabled()
        .background(SidebarGeometryAnchor(id: target) { presenter.anchors.apply($1, for: $0) })
        .help(WindowMenuStrings.showWorkspace(workspace.name))
        .accessibilityLabel(workspace.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

//////////////////
