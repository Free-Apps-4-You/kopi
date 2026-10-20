import Combine
import SwiftUI

/// Mutable state of one view, for the panel's hover flags and entrance animation.
///
/// `@State` is a macro that needs the SwiftUI macro plugin, which a machine with the
/// command line tools alone does not ship; `@StateObject` is an ordinary property
/// wrapper and expands everywhere, so the panel keeps its local state here.
final class PanelState<Value>: ObservableObject {
    @Published var value: Value

    init(_ value: Value) {
        self.value = value
    }

    /// Changes the value inside an explicit animation.
    func set(_ value: Value, animation: Animation?) {
        guard let animation else {
            self.value = value
            return
        }
        withAnimation(animation) {
            self.value = value
        }
    }
}
