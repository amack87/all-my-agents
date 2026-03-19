import AppKit
import CoreText

/// Creates terminal fonts with a cascade fallback list so Unicode glyphs
/// (symbols, emoji, box-drawing) render correctly instead of as underscores.
enum FontFactory {
    static func terminalFont(size: CGFloat = 13) -> NSFont {
        let primary = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let fallbacks: [CTFontDescriptor] = [
            CTFontDescriptorCreateWithNameAndSize("Menlo" as CFString, size),
            CTFontDescriptorCreateWithNameAndSize("Apple Symbols" as CFString, size),
            CTFontDescriptorCreateWithNameAndSize("Apple Color Emoji" as CFString, size),
        ]
        let attrs: [CFString: Any] = [kCTFontCascadeListAttribute: fallbacks]
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(
            primary.fontDescriptor as CTFontDescriptor,
            attrs as CFDictionary
        )
        return CTFontCreateWithFontDescriptor(descriptor, size, nil) as NSFont
    }
}
