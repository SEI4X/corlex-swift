import Corlex
import SwiftUI

@main
struct CorlexExampleApp: App {
    init() {
        // The values come from the launch environment so the same build runs against any stack:
        //   SIMCTL_CHILD_CORLEX_KEY=ck_test_…  SIMCTL_CHILD_CORLEX_INGEST_URL=http://127.0.0.1:8787
        let env = ProcessInfo.processInfo.environment
        var options = CorlexOptions()
        if let ingest = env["CORLEX_INGEST_URL"].flatMap(URL.init(string:)) { options.endpoint = ingest }
        if let config = env["CORLEX_CONFIG_URL"].flatMap(URL.init(string:)) { options.configEndpoint = config }
        if env["CORLEX_CONSENT"] == "pending" { options.consent = .pending }
        options.flushInterval = 2
        options.debug = true
        Corlex.start(key: env["CORLEX_KEY"] ?? "ck_test_exampleexampleexampleexampleexampleexample", options: options)
        CrashLab.runRequestedCrash(env["CORLEX_EXAMPLE_CRASH"])
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
