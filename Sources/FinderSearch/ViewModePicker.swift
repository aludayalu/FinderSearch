import SwiftUI
import AppKit

/// Two-segment view switch (icons, list); the gallery/columns modes moved to
/// the View menu (⌘3/⌘4) and the background context menu.
struct ViewModePicker: NSViewRepresentable {
    @Binding var selection: FileViewMode
    private static let modes: [FileViewMode] = [.icons, .list]
    private static let height: CGFloat = 28

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        makeControl(coordinator: context.coordinator)
    }

    func makeControl(coordinator: Coordinator) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            frame: NSRect(
                x: 0, y: 0,
                width: 84, height: Self.height))
        control.segmentCount = Self.modes.count
        control.trackingMode = .selectOne
        control.segmentStyle = .automatic
        control.target = coordinator
        control.action = #selector(Coordinator.selectMode(_:))
        control.setAccessibilityLabel("View")
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        for (index, mode) in Self.modes.enumerated() {
            let image = NSImage(
                systemSymbolName: mode.symbol, accessibilityDescription: mode.title)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
            control.setImage(image, forSegment: index)
            control.setImageScaling(.scaleProportionallyDown, forSegment: index)
            control.setWidth(38, forSegment: index)
            control.setToolTip(mode.title, forSegment: index)
        }
        coordinator.update(control)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.update(control)
    }

    @MainActor final class Coordinator: NSObject {
        var selection: Binding<FileViewMode>
        init(selection: Binding<FileViewMode>) { self.selection = selection }

        func update(_ control: NSSegmentedControl) {
            let index = ViewModePicker.modes.firstIndex(of: selection.wrappedValue) ?? -1
            if control.selectedSegment != index { control.selectedSegment = index }
        }

        @objc func selectMode(_ control: NSSegmentedControl) {
            guard ViewModePicker.modes.indices.contains(control.selectedSegment) else { return }
            selection.wrappedValue = ViewModePicker.modes[control.selectedSegment]
        }
    }
}
