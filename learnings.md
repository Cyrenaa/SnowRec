2026-08-03: Preset dialogs gained 确认/取消 buttons (5 alerts in PresetFlows); QA via --preset-test bypasses dialogs, so verify by code inspection + build.
2026-08-03: Preset Codable encodes optional fields via encodeIfPresent, so a new `Bool?` + snake_case CodingKey round-trips legacy state files byte-identically (key omitted when nil).
