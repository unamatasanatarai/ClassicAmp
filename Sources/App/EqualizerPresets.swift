import Foundation

public struct EqualizerPreset: Equatable, Codable {
    public let name: String
    public let preamp: Float // dB (-12.0 to +12.0)
    public let bands: [Float] // 10 bands in dB (-12.0 to +12.0)

    public init(name: String, preamp: Float = 0, bands: [Float]) {
        self.name = name
        self.preamp = preamp
        self.bands = bands
    }
}

public enum EqualizerPresets {
    public static let bandFrequencies: [Float] = [
        60.0, 170.0, 310.0, 600.0, 1000.0, 3000.0, 6000.0, 12000.0, 14000.0, 16000.0
    ]

    public static let factoryPresets: [EqualizerPreset] = [
        EqualizerPreset(name: "Flat", preamp: 0.0, bands: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        EqualizerPreset(name: "Classical", preamp: 0.0, bands: [4.8, 4.8, 3.6, 2.4, -1.2, -1.2, 0.0, 2.4, 3.6, 4.8]),
        EqualizerPreset(name: "Club", preamp: 0.0, bands: [0.0, 0.0, 2.4, 4.8, 4.8, 4.8, 2.4, 0.0, 0.0, 0.0]),
        EqualizerPreset(name: "Dance", preamp: 0.0, bands: [8.4, 6.0, 2.4, 0.0, 0.0, -4.8, -6.0, -6.0, 0.0, 0.0]),
        EqualizerPreset(name: "Laptop/Headphones", preamp: 0.0, bands: [3.6, 9.6, 4.8, -2.4, -1.2, 1.2, 3.6, 7.2, 9.6, 10.8]),
        EqualizerPreset(name: "Large Hall", preamp: 0.0, bands: [9.6, 9.6, 4.8, 4.8, 0.0, -3.6, -3.6, -3.6, 0.0, 0.0]),
        EqualizerPreset(name: "Party", preamp: 0.0, bands: [6.0, 6.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 6.0, 6.0]),
        EqualizerPreset(name: "Pop", preamp: 0.0, bands: [-1.2, 1.2, 6.0, 7.2, 4.8, -1.2, -2.4, -2.4, -1.2, -1.2]),
        EqualizerPreset(name: "Reggae", preamp: 0.0, bands: [0.0, 0.0, -1.2, -4.8, 0.0, 6.0, 6.0, 0.0, 0.0, 0.0]),
        EqualizerPreset(name: "Rock", preamp: 0.0, bands: [7.2, 4.8, -4.8, -7.2, -3.6, 3.6, 7.2, 9.6, 9.6, 9.6]),
        EqualizerPreset(name: "Soft", preamp: 0.0, bands: [4.8, 1.2, 0.0, -2.4, 0.0, 3.6, 7.2, 8.4, 9.6, 10.8]),
        EqualizerPreset(name: "Ska", preamp: 0.0, bands: [-2.4, -4.8, -3.6, -1.2, 3.6, 4.8, 7.2, 8.4, 9.6, 8.4]),
        EqualizerPreset(name: "Full Bass", preamp: 0.0, bands: [8.4, 8.4, 8.4, 4.8, 1.2, -3.6, -7.2, -9.6, -10.8, -10.8]),
        EqualizerPreset(name: "Soft Rock", preamp: 0.0, bands: [3.6, 3.6, 2.4, -1.2, -3.6, -4.8, -2.4, 2.4, 7.2, 8.4]),
        EqualizerPreset(name: "Full Treble", preamp: 0.0, bands: [-8.4, -8.4, -8.4, -3.6, 2.4, 9.6, 12.0, 12.0, 12.0, 12.0]),
        EqualizerPreset(name: "Full Bass & Treble", preamp: 0.0, bands: [6.0, 4.8, 0.0, -6.0, -4.8, 1.2, 7.2, 9.6, 10.8, 10.8]),
        EqualizerPreset(name: "Live", preamp: 0.0, bands: [-3.6, 0.0, 3.6, 4.8, 4.8, 4.8, 3.6, 2.4, 2.4, 2.4]),
        EqualizerPreset(name: "Techno", preamp: 0.0, bands: [7.2, 4.8, 0.0, -4.8, -4.8, 0.0, 7.2, 8.4, 8.4, 7.2])
    ]

    /// User-defined presets (persisted in state.json).
    public static var customPresets: [EqualizerPreset] = [] {
        didSet { Events.markDirty() }
    }

    public static func saveCustomPreset(_ preset: EqualizerPreset) {
        if let idx = customPresets.firstIndex(where: { $0.name == preset.name }) {
            customPresets[idx] = preset
        } else {
            customPresets.append(preset)
        }
    }

    public static func deleteCustomPreset(named name: String) {
        customPresets.removeAll { $0.name == name }
    }

    public static func matchPreset(forGenre genre: String) -> EqualizerPreset? {
        let g = genre.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if g.contains("rock") {
            return factoryPresets.first { $0.name == "Rock" }
        } else if g.contains("pop") {
            return factoryPresets.first { $0.name == "Pop" }
        } else if g.contains("classic") || g.contains("orchestr") || g.contains("symphon") {
            return factoryPresets.first { $0.name == "Classical" }
        } else if g.contains("dance") || g.contains("edm") || g.contains("house") {
            return factoryPresets.first { $0.name == "Dance" }
        } else if g.contains("techno") || g.contains("trance") || g.contains("electro") {
            return factoryPresets.first { $0.name == "Techno" }
        } else if g.contains("club") {
            return factoryPresets.first { $0.name == "Club" }
        } else if g.contains("reggae") || g.contains("dub") {
            return factoryPresets.first { $0.name == "Reggae" }
        } else if g.contains("ska") {
            return factoryPresets.first { $0.name == "Ska" }
        } else if g.contains("live") || g.contains("concert") {
            return factoryPresets.first { $0.name == "Live" }
        } else if g.contains("electronic") || g.contains("idm") || g.contains("drum") || g.contains("dubstep") {
            return factoryPresets.first { $0.name == "Techno" }
        } else if g.contains("hip") || g.contains("rap") || g.contains("r&b") || g.contains("funk") || g.contains("soul") {
            return factoryPresets.first { $0.name == "Full Bass" }
        } else if g.contains("jazz") || g.contains("blues") || g.contains("acoustic") || g.contains("folk") {
            return factoryPresets.first { $0.name == "Soft" }
        } else if g.contains("party") || g.contains("disco") {
            return factoryPresets.first { $0.name == "Party" }
        }
        return factoryPresets.first { $0.name == "Flat" }
    }
}
