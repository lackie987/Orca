// The visible lifecycle of the local service. Kept out of the controller so window state handling
// reads against a small value type instead of the process machinery.

import Foundation

/// Lifecycle of the local `dsh web` process that backs the Orca window.
enum ServiceState: Equatable {
    case idle
    case starting(String)
    case ready(URL)
    case failed(String)

    var isStarting: Bool {
        if case .starting = self { return true }
        return false
    }
}
