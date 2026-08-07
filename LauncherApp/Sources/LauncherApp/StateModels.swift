import Foundation

/// Action type of a saved preset. Raw values match the launcher.py strings.
enum PresetAction: String, Codable, Sendable {
    case subtitle
    case radio
    case tver
}

/// A saved recording preset, mirroring the three dict forms launcher.py
/// appends (subtitle / radio / tver). All action-specific fields are optional
/// because each action type only fills the fields it needs.
struct Preset: Codable, Sendable {
    var name: String
    var action: PresetAction
    var channel: String?
    var station: String?
    var timeStart: String?
    var timeEnd: String?
    var startAt: String?
    var duration: String?
    var output: String?
    var endTime: String?
    var toVideo: Bool?
    var translate: Bool?

    enum CodingKeys: String, CodingKey {
        case name, action, channel, station, duration, output
        case timeStart = "time_start"
        case timeEnd = "time_end"
        case startAt = "start_at"
        case endTime = "end_time"
        case toVideo = "to_video"
        case translate
    }
}

/// One history entry. `pid` and `log` may be MISSING in real files
/// (the current state file's 4th entry has neither key), so both are
/// optional. `cmd` always starts with "caffeinate".
struct HistoryEntry: Codable, Sendable {
    var label: String
    var cmd: [String]
    var status: String
    var pid: Int?
    var log: String?
}

/// The whole state file (`~/.script_launcher_dev.json`). Top-level keys may be
/// missing from real files, in which case they default to empty arrays.
struct StateFile: Codable, Sendable {
    var presets: [Preset]
    var history: [HistoryEntry]

    init(presets: [Preset] = [], history: [HistoryEntry] = []) {
        self.presets = presets
        self.history = history
    }

    enum CodingKeys: String, CodingKey {
        case presets, history
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        presets = try container.decodeIfPresent([Preset].self, forKey: .presets) ?? []
        history = try container.decodeIfPresent([HistoryEntry].self, forKey: .history) ?? []
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(presets, forKey: .presets)
        try container.encode(history, forKey: .history)
    }
}
