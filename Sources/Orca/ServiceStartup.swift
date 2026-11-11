// The ordered stages a launch walks through while looking for a service to attach to. Each stage
// hands the launch to the next one when it cannot attach, so the fallback order lives here as data
// rather than as a branch in the controller.

/// A synchronous record read, a port-owner lookup that only reuses a verified dsh listener, then a
/// fresh launch.
enum ServiceStartupStage {
    case record
    case reuse
    case launch

    /// The next stage to try when this one cannot attach to a running service.
    var fallback: ServiceStartupStage? {
        switch self {
        case .record: return .reuse
        case .reuse: return .launch
        case .launch: return nil
        }
    }
}
