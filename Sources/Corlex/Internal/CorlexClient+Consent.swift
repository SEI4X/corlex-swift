import Foundation

/// Consent rules of docs: services/ingest/docs/protocol.md §4.1:
/// without consent no request at all and nothing on disk; events tracked meanwhile wait in
/// memory and are sent after `optIn()`; `optOut()` clears everything and survives restarts.
extension CorlexClient {
    func optIn() {
        let expected = binding.refusalToken
        queue.async { self.grant(persistChoice: true, expectedRefusal: expected) }
    }

    func optOut() {
        let expected = binding.beginRevocation()
        if env.installGlobalHooks { CrashReporter.shared.disable(deleteReports: false) }
        env.transport.pause()
        queue.async {
            self.binding.completeRevocation(expected: expected)
            self.deny(persistChoice: true)
        }
    }

    /// `persistChoice` is false when App Tracking Transparency, not the app, decided.
    func grant(persistChoice: Bool, expectedRefusal: PrivacyRecord?) {
        guard binding.refusalToken == expectedRefusal else { return }
        if consent == .granted, binding.canSend {
            if persistChoice { binding.rememberChoice(ifRefusal: expectedRefusal); storage?.writeText("granted", to: Self.consentFile) }
            return
        }
        env.transport.pause()
        let preservePending = binding.grant(ifRefusal: expectedRefusal) { [env] in
            if env.installGlobalHooks { CrashReporter.shared.disable(deleteReports: false) }
        }
        storage = binding.storage
        consent = CorlexConsent(rawValue: binding.state.rawValue) ?? .pending
        if !preservePending {
            runtime?.sender.stop()
            runtime?.remote.stop(wipe: false)
            runtime = nil
            exposed.removeAll()
            lastScreen = nil
        }
        guard consent != .denied else { return }
        env.transport.resume()
        if consent == .granted { installCrashHandlers() }
        if let runtime {
            runtime.identity.persist()
            runtime.queue.enablePersistence()
            runtime.sender.resume()
        } else {
            makeRuntime()
            if env.installGlobalHooks { observeApp() }
            captureAppOpen()
        }
        if consent != .granted { return }
        processPendingCrashes()
        startRemoteConfig()
        runtime?.sender.schedule()
    }

    /// Stops collecting and removes everything the SDK stored on this device, the saved config too.
    func deny(persistChoice: Bool) {
        consent = .denied
        env.transport.pause()
        if binding.state != .denied && binding.isCurrent { binding.revoke() }
        exposed.removeAll()
        runtime?.remote.stop(wipe: true)
        runtime?.sender.stop()
        runtime?.queue.clear()
        runtime?.identity.wipe()
        if env.installGlobalHooks {
            CrashReporter.shared.disable(deleteReports: true)
            ScreenTracker.stop()
        }
        // The ledger already fenced and removed every SDK-owned scope; stale handles cannot write.
        storage = nil
    }

    // MARK: - App lifecycle

    /// Observers, the UIKit screen hook. Called once the runtime exists.
    func observeApp() {
        if options.autocapture.uiKitScreens, consent == .granted {
            ScreenTracker.start { [weak self] name in self?.screen(name, [:], source: "uikit") }
        }
        guard !observing else { return }
        observing = true
        let handlers = Lifecycle.Handlers(
            didEnterBackground: { [weak self] in self?.appDidEnterBackground() },
            willEnterForeground: { [weak self] in self?.appWillEnterForeground() },
            didBecomeActive: { [weak self] in self?.appDidBecomeActive() }
        )
        DispatchQueue.main.async { if self.binding.isCurrent { self.lifecycle = Lifecycle(handlers: handlers) } }
    }

    /// Main thread. The last events and a flush get a few more seconds of background time.
    private func appDidEnterBackground() {
        BackgroundTask.run { finish in
            queue.async {
                if self.options.autocapture.lifecycle {
                    self.capture(EventName.appBackground, [:], CaptureMeta())
                }
                self.hasBeenInBackground = true
                guard let runtime = self.runtime, self.consent == .granted else { return finish() }
                runtime.sender.flush(completion: finish)
            }
        }
    }

    private func appWillEnterForeground() {
        queue.async {
            self.observeTracking()
            if self.options.autocapture.lifecycle, self.hasBeenInBackground {
                self.capture(EventName.appForeground, [:], CaptureMeta())
            }
            // Where a batch that failed in the background is retried.
            if self.consent == .granted { self.runtime?.sender.flush() }
        }
    }

    /// `consent: .att`: the answer given in the app's own flow takes effect without a restart.
    private func appDidBecomeActive() {
        guard options.consent == .att else { return }
        queue.async { self.observeTracking() }
    }

    func observeTracking() {
        guard options.consent == .att, binding.ceilingChanged else { return }
        env.transport.pause()
        let changed = binding.observeCeiling { [env] in
            if env.installGlobalHooks { CrashReporter.shared.disable(deleteReports: false) }
        }
        guard changed else { return }
        runtime?.sender.stop()
        runtime?.remote.stop(wipe: false)
        runtime = nil
        exposed.removeAll()
        lastScreen = nil
        storage = binding.storage
        consent = CorlexConsent(rawValue: binding.state.rawValue) ?? .pending
        guard consent != .denied else { return }
        makeRuntime()
        captureAppOpen()
        if consent == .granted {
            env.transport.resume()
            installCrashHandlers()
            processPendingCrashes()
            startRemoteConfig()
        }
    }
}
