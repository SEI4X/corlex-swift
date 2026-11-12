import Corlex
import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "house") }
            CatalogView()
                .tabItem { Label("Catalog", systemImage: "list.bullet") }
            PrivacyView()
                .tabItem { Label("Privacy", systemImage: "lock") }
        }
    }
}

/// Events, identity and Remote Config.
struct HomeView: View {
    @State private var banner = Corlex.flag("welcome_banner", default: "Welcome to the Corlex example")
    @State private var newCheckout = Corlex.flag("show_new_checkout", default: false)
    @State private var taps = 0

    var body: some View {
        NavigationView {
            List {
                Section("Remote Config") {
                    Text(banner).accessibilityIdentifier("banner")
                    HStack {
                        Text("show_new_checkout")
                        Spacer()
                        Text(newCheckout ? "on" : "off").foregroundColor(.secondary)
                    }
                    Button("Reload values") { reload() }
                }
                Section("Events") {
                    Button("Track a purchase") {
                        taps += 1
                        Corlex.track("purchase", properties: ["plan": "pro", "amount": 12.5, "tap": taps])
                    }
                    Button("Identify as user_42") {
                        Corlex.identify("user_42", traits: ["plan": "pro"])
                        Corlex.setUserProperties(["locale": "en"])
                    }
                    Button("Log out (reset)") { Corlex.reset() }
                }
            }
            .navigationTitle("Corlex example")
        }
        .navigationViewStyle(.stack)
        .corlexScreen("Home")
    }

    private func reload() {
        Task {
            await Corlex.config.refresh()
            banner = Corlex.flag("welcome_banner", default: "Welcome to the Corlex example")
            newCheckout = Corlex.flag("show_new_checkout", default: false)
        }
    }
}

struct CatalogView: View {
    private let products = ["Espresso", "Flat white", "Cold brew"]

    var body: some View {
        NavigationView {
            List(products, id: \.self) { name in
                NavigationLink(name) { ProductView(name: name) }
            }
            .navigationTitle("Catalog")
        }
        .navigationViewStyle(.stack)
        .corlexScreen("Catalog")
    }
}

struct ProductView: View {
    let name: String

    var body: some View {
        VStack(spacing: 16) {
            Text(name).font(.title)
            Button("Add to cart") {
                Corlex.track("add_to_cart", properties: ["product": name])
            }
        }
        // A fixed screen name per screen: the product is a property, never part of the name.
        .corlexScreen("Product", properties: ["product": name])
    }
}
