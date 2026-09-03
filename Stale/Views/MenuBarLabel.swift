import SwiftUI
import AppKit

/// The status item content. Template (monochrome) clock while everything is fresh/aging;
/// tinted clock-with-badge plus a count once something is stale or rotten.
struct MenuBarLabel: View {
    let tier: StalenessTier?
    let attentionCount: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: MenuBarIcon.image(for: tier))
            if attentionCount > 0 {
                Text("\(attentionCount)")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard let tier else { return "Stale: no open pull requests" }
        return "Stale: worst tier \(tier.label), \(attentionCount) needing attention"
    }
}

enum MenuBarIcon {
    static func image(for tier: StalenessTier?) -> NSImage {
        let symbolName: String
        let tint: NSColor?
        switch tier {
        case .stale:
            symbolName = "clock.badge.exclamationmark"
            tint = .systemOrange
        case .rotten:
            symbolName = "clock.badge.exclamationmark"
            tint = .systemRed
        default:
            symbolName = "clock"
            tint = nil
        }

        var configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        if let tint {
            configuration = configuration.applying(.init(paletteColors: [tint]))
        }

        let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Stale")!
        let image = base.withSymbolConfiguration(configuration) ?? base
        // Template images adapt to light/dark menu bars; tinted ones must not be templated
        // or the colour is thrown away.
        image.isTemplate = (tint == nil)
        return image
    }
}
