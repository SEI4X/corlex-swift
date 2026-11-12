import Foundation

/// Deliberate crashes, to see the reporter and the symbolication work. Every function is
/// `@inline(never)`, and its declaration line carries a `symtab-marker` comment:
/// Tools/Tests/CorlexSymtabTests finds the lines by them to check that a symtab maps addresses
/// to the right function, file and line.
enum CrashLab {
    /// `CORLEX_EXAMPLE_CRASH=trap|segfault|exception` crashes a second after launch (for scripts).
    static func runRequestedCrash(_ kind: String?) {
        guard let kind else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            switch kind {
            case "segfault": segfault()
            case "exception": exception()
            default: trap()
            }
        }
    }

    @inline(never)
    static func trap() { // symtab-marker: trap
        level2(missing: nil)
    }

    @inline(never)
    static func level2(missing: Int?) { // symtab-marker: level2
        level3(missing)
    }

    @inline(never)
    static func level3(_ value: Int?) { // symtab-marker: level3
        print("about to unwrap \(value!)")
    }

    @inline(never)
    static func segfault() { // symtab-marker: segfault
        let pointer = UnsafeMutablePointer<Int>(bitPattern: 0x10)!
        pointer.pointee = 1
    }

    @inline(never)
    static func exception() { // symtab-marker: exception
        NSException(
            name: NSExceptionName("CorlexExampleException"),
            reason: "Deliberate NSException from the Corlex example",
            userInfo: nil
        ).raise()
    }
}
