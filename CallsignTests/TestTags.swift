import Testing

extension Tag {
    // Needs a live desktop session: real windows, private SkyLight state, or wall-clock timing.
    // The Unit test plan skips these.
    @Tag static var integration: Self
}
