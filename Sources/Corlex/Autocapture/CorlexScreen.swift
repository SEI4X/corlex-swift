import SwiftUI

private struct CorlexScreenModifier: ViewModifier {
    let name: String
    let properties: [String: Any]?

    func body(content: Content) -> some View {
        content.onAppear {
            Corlex.screen(name, properties: properties, source: "swiftui")
        }
    }
}

public extension View {
    /// Reports a `screen_view` named `name` each time this view appears.
    ///
    ///     ContentView().corlexScreen("Home")
    ///
    /// Use a fixed name per screen, never one built from user data (ids, e-mails, search text).
    func corlexScreen(_ name: String, properties: [String: Any]? = nil) -> some View {
        modifier(CorlexScreenModifier(name: name, properties: properties))
    }
}
