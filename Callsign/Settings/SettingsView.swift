import SwiftUI

enum SettingsPage {
    case general, appearance, about
}

struct SettingsView: View {
    let controller: AppController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection: SettingsPage = .general
    @State private var transitioning = false
    @State private var transitionGeneration = 0

    var body: some View {
        // Closure, not a method reference: Swift 6.2 crashes generating the isolation thunk.
        TabView(selection: Binding(get: { selection }, set: { selectPage($0) })) {
            Tab("General", systemImage: "gearshape", value: .general) {
                GeneralSettingsView(controller: controller)
            }
            Tab("Appearance", systemImage: "paintpalette", value: .appearance) {
                AppearanceSettingsView(controller: controller)
            }
            Tab("About", systemImage: "info.circle", value: .about) {
                AboutSettingsView()
            }
        }
        .frame(width: 600)
        // Use each selected pane's ideal height instead of the window's default height.
        // ponytail: no screen-height cap; add one if panes outgrow smaller displays.
        .fixedSize(horizontal: false, vertical: true)
        .windowResizeAnchor(.topLeading)
        // Opacity preserves the pane's layout while the native window resizes.
        .animation(nil) { content in
            content.opacity(transitioning ? 0 : 1)
        }
        .allowsHitTesting(!transitioning)
        .accessibilityHidden(transitioning)
        .onAppear(perform: controller.settingsDidAppear)
        .onDisappear {
            transitionGeneration += 1
            transitioning = false
        }
    }

    private func selectPage(_ page: SettingsPage) {
        guard page != selection || transitioning else { return }
        transitionGeneration += 1
        let generation = transitionGeneration
        transitioning = !reduceMotion
        withAnimation(reduceMotion ? nil : .linear(duration: 0.2), completionCriteria: .removed) {
            selection = page
        } completion: {
            // A superseded transition must not reveal content during a newer resize.
            guard generation == transitionGeneration else { return }
            transitioning = false
        }
    }
}
