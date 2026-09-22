import Domain
import SwiftUI

@MainActor
struct ActivityTabBar: View {
    @Bindable var model: ThreadListModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.layoutDirection) private var layoutDirection
    @GestureState private var dragPosition: CGFloat?
    static let height: CGFloat = 56

    private let segmentWidth: CGFloat = 38
    private let thumbWidth: CGFloat = 36
    private let thumbHeight: CGFloat = 28
    private var categories: [ActivityCategory?] { [nil] + ActivityCategory.allCases.map(Optional.some) }
    private var selectedIndex: Int { categories.firstIndex(of: model.activityFilter) ?? 0 }
    private var selectionAnimation: Animation? { reduceMotion ? nil : .snappy(duration: 0.25) }
    private var position: CGFloat { dragPosition ?? CGFloat(selectedIndex) * segmentWidth }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(categories.indices, id: \.self) { index in
                tab(at: index)
            }
        }
        .background(alignment: .leading) {
            thumb
                .offset(x: layoutDirection == .rightToLeft ? -position : position)
                .animation(dragPosition == nil ? selectionAnimation : nil, value: position)
                .accessibilityHidden(true)
        }
        .coordinateSpace(name: "activitySegments")
        .simultaneousGesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named("activitySegments"))
                .updating($dragPosition) { value, position, transaction in
                    transaction.animation = nil
                    position = clampedPosition(for: value.location.x)
                }
                .onEnded { value in
                    select(Int((clampedPosition(for: value.location.x) / segmentWidth).rounded()))
                }
        )
        .padding(4)
        .background {
            if reduceTransparency {
                Capsule().fill(Color(nsColor: .windowBackgroundColor))
            } else {
                Capsule().fill(.ultraThinMaterial)
            }
        }
        .padding(.bottom, 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Activity Category")
    }

    @ViewBuilder
    private var thumb: some View {
        if reduceTransparency {
            Capsule()
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay { Capsule().strokeBorder(.primary.opacity(0.25), lineWidth: 1) }
                .frame(width: thumbWidth, height: thumbHeight)
        } else {
            Color.clear
                .frame(width: thumbWidth, height: thumbHeight)
                .glassEffect(.regular.interactive(), in: .capsule)
        }
    }

    private func tab(at index: Int) -> some View {
        let category = categories[index]
        let title = category?.title ?? String(localized: "All")
        let isSelected = selectedIndex == index
        return Button {
            select(index)
        } label: {
            Image(systemName: category?.symbol ?? "tray.full")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(width: thumbWidth, height: thumbHeight)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func clampedPosition(for x: CGFloat) -> CGFloat {
        let width = CGFloat(categories.count - 1) * segmentWidth + thumbWidth
        let leadingX = layoutDirection == .rightToLeft ? width - x : x
        return min(max(leadingX - thumbWidth / 2, 0), CGFloat(categories.count - 1) * segmentWidth)
    }

    private func select(_ index: Int) {
        let category = categories[index]
        model.activityFilter = category
    }
}
