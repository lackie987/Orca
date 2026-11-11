// Holds the two answers one adoption gathers. Which answer decides what lives in the controller:
// the port owner decides the adoption, the probe only decides whether it is worth keeping.

/// Answers gathered while adopting a service left behind by an earlier launch.
struct AdoptionAnswers {
    private(set) var healthy: Bool?
    private(set) var owner: Int32?
    private(set) var trusted = false

    /// Records the health probe's answer.
    mutating func recordHealth(_ healthy: Bool) {
        self.healthy = healthy
    }

    /// Records which process owns the port, and whether its argv belongs to a dsh service.
    mutating func recordOwner(_ owner: Int32?, trusted: Bool) {
        self.owner = owner
        self.trusted = trusted
    }
}
