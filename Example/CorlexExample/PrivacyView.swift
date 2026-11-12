import Corlex
import SwiftUI

/// Consent and the crash buttons.
struct PrivacyView: View {
    @State private var consent = Corlex.consent

    var body: some View {
        NavigationView {
            List {
                Section("Consent: \(consent.rawValue)") {
                    Button("Opt in") { Corlex.optIn(); refresh() }
                    Button("Opt out") { Corlex.optOut(); refresh() }
                }
                Section("Crash reporter (the app quits; relaunch to send the report)") {
                    Button("Swift trap (force-unwrap nil)") { CrashLab.trap() }
                    Button("Segmentation fault") { CrashLab.segfault() }
                    Button("Uncaught NSException") { CrashLab.exception() }
                }
                .foregroundColor(.red)
            }
            .navigationTitle("Privacy")
        }
        .navigationViewStyle(.stack)
        .corlexScreen("Privacy")
    }

    private func refresh() {
        // The call returns at once; the state follows on the SDK's queue.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { consent = Corlex.consent }
    }
}
