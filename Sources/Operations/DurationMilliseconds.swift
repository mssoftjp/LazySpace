import Foundation

extension Duration {
    /// `seconds * 1000 + attoseconds / 1e15`. Arrange and focus timing share this.
    var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}
