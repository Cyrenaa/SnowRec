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

    /// Statuses that make a task "active" (launcher.py:257). Internal so
    /// AppDelegate.rebuildMenu() can reuse it for the no-active-tasks clear
    /// (launcher.py:263-264).
    static let activeStatuses = ["运行中", "等待启动"]

    /// Builds the complete menu tree (launcher.py:255-306).
    static func buildMenu(tasks: [Task], state: StateFile) -> NSMenu {
        let menu = NSMenu()
        let active = tasks.filter { activeStatuses.contains($0.status) }

        // ── 任务 ── header + one item per active task (launcher.py:258-262).
        // Each item carries its LIVE Task as representedObject so
        // AppDelegate can wire taskInfo without title parsing (todo 20).
        if !active.isEmpty {
            menu.addItem(disabledItem("── 任务 ──"))
            for task in active {
                let item = disabledItem(task.menuTitle)
                item.representedObject = task
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        // 下载字幕 / 录制广播 / 录制 TVer (launcher.py:266-268).
        for title in ["下载字幕", "录制广播", "录制 TVer", "翻译字幕"] {
            menu.addItem(disabledItem(title))
        }

        // 其他功能 — extensible category (launcher parity: none; additive).
        // Future features slot in as additional sub-items here.
        let otherFeatures = NSMenu()
        otherFeatures.addItem(disabledItem("YouTube 直播录制"))
        menu.addItem(parentItem("其他功能", submenu: otherFeatures))
        menu.addItem(.separator())

        // 收藏 — preset entries listed FLAT on the top level (user's
        // custom names keep their emoji; the section header mirrors the
        // "── 任务 ──" style). Each row carries a manage submenu
        // (修改收藏/删除收藏); clicking the row itself runs the preset.
        menu.addItem(disabledItem("── 收藏 ──"))
        for preset in state.presets {
            let manageMenu = NSMenu()
            manageMenu.addItem(disabledItem("  修改"))
            manageMenu.addItem(disabledItem("  删除"))
            menu.addItem(parentItem(preset.name, submenu: manageMenu))
        }
        menu.addItem(disabledItem("新建收藏..."))
        menu.addItem(.separator())

        // 最近 — parent item with submenu (launcher.py:284-297).
        // Status tag ONLY when the status is non-empty (launcher.py:287).
        // Each entry item carries its HistoryEntry as representedObject
        // (todo 20: never parse the display title — it has the tag).
        let historyMenu = NSMenu()
        for entry in state.history {
            let statusTag = entry.status.isEmpty ? "" : " [\(entry.status)]"
            let item = disabledItem("  \(entry.label)\(statusTag)")
            item.representedObject = entry
            historyMenu.addItem(item)
        }
        if historyMenu.items.isEmpty {
            historyMenu.addItem(disabledItem("  (空)"))
        } else {
            historyMenu.addItem(disabledItem("  清除全部"))
        }
        menu.addItem(parentItem("最近", submenu: historyMenu))

        // DeepSeek API key settings (wired in AppDelegate.attachMenuActions).
        menu.addItem(disabledItem("设置 DeepSeek API Key..."))

        // Stop-all + restart + quit (launcher.py:299-304).
        menu.addItem(.separator())
        if !active.isEmpty {
            menu.addItem(disabledItem("停止全部"))
        }
        menu.addItem(.separator())
        menu.addItem(disabledItem("重启"))
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

    /// Parent item carrying a submenu (收藏 / 最近 headers). ENABLED but
    /// action-less (rumps header semantics): no click action, yet the submenu
    /// must expand on hover — a disabled NSMenuItem does NOT open its submenu.
    private static func parentItem(_ title: String, submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = true
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
