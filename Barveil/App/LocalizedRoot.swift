// Applies the user's in-app language without relaunching the process. The
// root observes Preferences so changing the Picker immediately re-renders
// both the menu-bar panel and the settings window.

import SwiftUI

struct LocalizedRoot<Content: View>: View {
    @EnvironmentObject private var preferences: Preferences
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .environment(\.locale, preferences.resolvedLocale)
    }
}
