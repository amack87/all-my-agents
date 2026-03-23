import SwiftUI

/// 12-color palette for machine badges, matching the web app.
/// Colors are assigned stably in discovery order.
enum MachineColors {
    struct MachineColor {
        let foreground: Color
        let background: Color
    }

    private static let palette: [MachineColor] = [
        MachineColor(foreground: Color(red: 0.506, green: 0.549, blue: 0.973), background: Color(red: 0.388, green: 0.400, blue: 0.945).opacity(0.15)),  // indigo
        MachineColor(foreground: Color(red: 0.431, green: 0.906, blue: 0.718), background: Color(red: 0.204, green: 0.827, blue: 0.600).opacity(0.15)),  // emerald
        MachineColor(foreground: Color(red: 0.984, green: 0.573, blue: 0.235), background: Color(red: 0.984, green: 0.573, blue: 0.235).opacity(0.15)),  // orange
        MachineColor(foreground: Color(red: 0.655, green: 0.545, blue: 0.980), background: Color(red: 0.576, green: 0.200, blue: 0.918).opacity(0.15)),  // purple
        MachineColor(foreground: Color(red: 0.220, green: 0.741, blue: 0.973), background: Color(red: 0.055, green: 0.647, blue: 0.914).opacity(0.15)),  // sky
        MachineColor(foreground: Color(red: 0.984, green: 0.443, blue: 0.522), background: Color(red: 0.957, green: 0.247, blue: 0.369).opacity(0.15)),  // rose
        MachineColor(foreground: Color(red: 0.980, green: 0.800, blue: 0.082), background: Color(red: 0.918, green: 0.702, blue: 0.031).opacity(0.15)),  // yellow
        MachineColor(foreground: Color(red: 0.369, green: 0.918, blue: 0.820), background: Color(red: 0.176, green: 0.831, blue: 0.749).opacity(0.15)),  // teal
        MachineColor(foreground: Color(red: 0.976, green: 0.451, blue: 0.086), background: Color(red: 0.976, green: 0.451, blue: 0.086).opacity(0.15)),  // amber
        MachineColor(foreground: Color(red: 0.753, green: 0.518, blue: 0.988), background: Color(red: 0.659, green: 0.333, blue: 0.969).opacity(0.15)),  // violet
        MachineColor(foreground: Color(red: 0.133, green: 0.827, blue: 0.933), background: Color(red: 0.133, green: 0.827, blue: 0.933).opacity(0.15)),  // cyan
        MachineColor(foreground: Color(red: 0.639, green: 0.902, blue: 0.208), background: Color(red: 0.639, green: 0.902, blue: 0.208).opacity(0.15)),  // lime
    ]

    private static var colorMap: [String: Int] = [:]

    static func color(for machineName: String?) -> MachineColor {
        guard let name = machineName else { return palette[0] }
        if let idx = colorMap[name] { return palette[idx] }
        let idx = colorMap.count % palette.count
        colorMap[name] = idx
        return palette[idx]
    }
}
