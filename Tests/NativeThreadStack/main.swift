import CCorlexCrash
import Darwin
import Foundation

precondition(Thread.isMainThread)
let host = CommandLine.arguments[1] == "host"
var original = stack_t()
precondition(sigaltstack(nil, &original) == 0)
if host {
    let memory = UnsafeMutableRawPointer.allocate(byteCount: 65536, alignment: 16)
    var provided = stack_t(ss_sp: memory, ss_size: 65536, ss_flags: 0)
    precondition(sigaltstack(&provided, nil) == 0)
    original = provided
} else {
    precondition(original.ss_flags & SS_DISABLE != 0, "fresh own-stack fixture already has a host stack")
}
let workerDone = DispatchSemaphore(value: 0)
DispatchQueue.global().async {
    var before = stack_t(), after = stack_t()
    precondition(sigaltstack(nil, &before) == 0)
    NativeCrashThreadStack.prepare()
    precondition(sigaltstack(nil, &after) == 0)
    precondition(before.ss_sp == after.ss_sp && before.ss_flags == after.ss_flags, "worker stack changed")
    workerDone.signal()
}
precondition(workerDone.wait(timeout: .now() + 2) == .success)
var ready = stack_t()
let deadline = Date().addingTimeInterval(2)
repeat {
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    precondition(sigaltstack(nil, &ready) == 0)
} while ready.ss_flags & SS_DISABLE != 0 && Date() < deadline
precondition(ready.ss_flags & SS_DISABLE == 0, "background startup did not prepare main stack")
if host { precondition(ready.ss_sp == original.ss_sp && ready.ss_size == original.ss_size, "host stack replaced") }
let prepared = ready.ss_sp
NativeCrashThreadStack.prepare()
precondition(sigaltstack(nil, &ready) == 0 && ready.ss_sp == prepared, "preparation was not idempotent")
precondition(NSGetUncaughtExceptionHandler() == nil, "pending preparation installed exception handler")
precondition(corlex_crash_open_report() == -1, "pending preparation armed capture")
print("Swift native preparation: \(host ? "host preserved" : "own stack"), worker/main hop, idempotence and pending capture disabled passed")
