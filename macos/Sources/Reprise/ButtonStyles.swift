import SwiftUI

/// Plain SwiftUI buttons otherwise ignore transparent padding and Spacer areas.
/// Apply the shape here, after the label has established its full row bounds.
struct RepriseRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A text or icon action with a real target, including its blank padding.
struct RepriseQuietButtonStyle: ButtonStyle {
    var minimumSize: CGFloat = 40
    var tint: Color = .accentColor

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .frame(minWidth: minimumSize, minHeight: minimumSize)
            .foregroundStyle(tint)
            .background(configuration.isPressed ? Color.primary.opacity(0.08) : .clear,
                in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.4)
    }
}
