import AppKit

/// Builds the status-item menu tree, item-for-item mirroring
/// launcher.py:255-306 `_rebuild_menu`.
///
/// rumps semantics: a MenuItem WITHOUT a callback renders disabled (grey),
/// which Swift expresses as `item.isEnabled = false`. Every item in this todo
/// is a placeholder (no target/action) — real callbacks arrive in todos
/// 18-21. Per plan D5, 收藏/最近 become NSMenu SUBMENUS for visual parity
/// with rumps' flat header items (a disabled parent item with a submenu still
/// opens on hover).
///
/// Pure function of (tasks, state) so it can be unit-tested and driven by the
/// `--dump-menu` QA flag without any GUI state.
enum MenuBuilder {

    /// Statuses that make a task "active" (launcher.py:257).
    private static let activeStatuses = ["运行中", "等待启动"]

    /// Builds the complete menu tree (launcher.py:255-306).
    static func buildMenu(tasks: [Task], state: StateFile) -> NSMenu {
        let menu = NSMenu()
        let active = tasks.filter { activeStatuses.contains($0.status) }

        // ── 任务 ── header + one item per active task (launcher.py:258-262).
        if !active.isEmpty {
            menu.addItem(disabledItem("── 任务 ──"))
            for task in active {
                menu.addItem(disabledItem(task.menuTitle))
            }
            menu.addItem(.separator())
        }

        // 下载字幕 / 录制广播 / 录制 TVer (launcher.py:266-268).
        for title in ["📝 下载字幕", "📻 录制广播", "📺 录制 TVer"] {
            menu.addItem(disabledItem(title))
        }
        menu.addItem(.separator())

        // ⭐ 收藏 — parent item with submenu (launcher.py:272-281).
        let presetsMenu = NSMenu()
        for preset in state.presets {
            presetsMenu.addItem(disabledItem("  \(preset.name)"))
        }
        presetsMenu.addItem(disabledItem("  ➕ 新建收藏..."))
        presetsMenu.addItem(disabledItem("  ✏️ 管理收藏..."))
        menu.addItem(parentItem("⭐ 收藏", submenu: presetsMenu))

        // 🕐 最近 — parent item with submenu (launcher.py:284-297).
        // Status tag ONLY when the status is non-empty (launcher.py:287).
        let historyMenu = NSMenu()
        for entry in state.history {
            let statusTag = entry.status.isEmpty ? "" : " [\(entry.status)]"
            historyMenu.addItem(disabledItem("  \(entry.label)\(statusTag)"))
        }
        if historyMenu.items.isEmpty {
            historyMenu.addItem(disabledItem("  (空)"))
        } else {
            historyMenu.addItem(disabledItem("  ❌ 清除全部"))
        }
        menu.addItem(parentItem("🕐 最近", submenu: historyMenu))

        // Stop-all + quit (launcher.py:299-303).
        menu.addItem(.separator())
        if !active.isEmpty {
            menu.addItem(disabledItem("⏹ 停止全部"))
        }
        menu.addItem(.separator())
        menu.addItem(disabledItem("退出"))

        return menu
    }

    /// Prints the menu tree as indented text for QA assertions:
    /// `> item` top-level, `  > item` submenu children, `---` separators,
    /// ` (disabled)` suffix on disabled items.
    static func dumpTree(_ menu: NSMenu) -> String {
        var lines: [String] = []
        for item in menu.items {
            appendItem(item, depth: 0, lines: &lines)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// rumps MenuItem-without-callback: greyed out, no action.
    private static func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// Disabled parent item carrying a submenu (收藏 / 最近 headers).
    private static func parentItem(_ title: String, submenu: NSMenu) -> NSMenuItem {
        let item = disabledItem(title)
        item.submenu = submenu
        return item
    }

    private static func appendItem(_ item: NSMenuItem, depth: Int, lines: inout [String]) {
        let indent = String(repeating: "  ", count: depth)
        if item.isSeparatorItem {
            lines.append(indent + "---")
            return
        }
        var line = indent + "> \(item.title)"
        if !item.isEnabled {
            line += " (disabled)"
        }
        lines.append(line)
        if let submenu = item.submenu {
            for child in submenu.items {
                appendItem(child, depth: depth + 1, lines: &lines)
            }
        }
    }
}
