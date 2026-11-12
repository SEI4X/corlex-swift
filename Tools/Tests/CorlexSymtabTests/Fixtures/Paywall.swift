import Foundation

struct Paywall {
    let basePrice: Double

    @inline(never)
    func discountedPrice(percent: Double) -> Double {
        let discount = basePrice * percent / 100
        return basePrice - discount
    }

    @inline(never)
    static func headline(for plan: String) -> String {
        switch plan {
        case "pro": return "Go Pro"
        default: return "Choose a plan"
        }
    }
}

@inline(never)
func checkout(total: Double) -> String {
    let paywall = Paywall(basePrice: total)
    return Paywall.headline(for: "pro") + " " + String(paywall.discountedPrice(percent: 10))
}

print(checkout(total: Double(CommandLine.arguments.count) * 10))
