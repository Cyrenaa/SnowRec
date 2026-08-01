import Darwin

/// History-status normalization and orphan-process recovery, mirroring
/// launcher.py `_normalize_history` (lines 207-221) and `_kill_orphan`
/// (lines 223-233) exactly.
///
/// Called once at application launch: every history entry's status is mapped
/// to the canonical three-value set ("成功" / "失败" / "运行"), and entries
/// whose status is (or becomes) "运行" have their leftover process group
/// terminated before the status is flipped to "失败" -- an app restart
/// cannot track them anymore.
enum OrphanRecovery {

    /// Normalizes every history entry in place, killing orphan process
    /// groups for entries whose status is "运行".
    static func recover(in state: inout StateFile) {
        for index in state.history.indices {
            let status = state.history[index].status
            if ["运行中", "已启动", "等待启动"].contains(status) {
                state.history[index].status = "运行"
            } else if status == "已完成" {
                state.history[index].status = "成功"
            } else if status != "成功" && status != "失败" && status != "运行" {
                state.history[index].status = "失败"
            }

            // A "运行" entry left over from a previous session cannot be
            // tracked after an app restart; treat it as interrupted.
            if state.history[index].status == "运行" {
                killOrphan(pid: state.history[index].pid)
                state.history[index].status = "失败"
            }
        }
    }

    /// Probes pid with kill(pid, 0) (returns 0 while the process exists,
    /// -1 with errno ESRCH/EPERM otherwise). If the process is alive,
    /// SIGTERMs its whole process group via kill(-pid, SIGTERM), which is
    /// exactly os.killpg semantics. ESRCH (process gone) and EPERM (not our
    /// process) are swallowed silently on both calls.
    private static func killOrphan(pid: Int?) {
        guard let pid = pid, pid > 0 else { return }
        if kill(pid_t(pid), 0) != 0 {
            return  // No such process, or not ours to signal
        }
        if kill(-pid_t(pid), SIGTERM) != 0 {
            return  // Group vanished between the probe and the kill
        }
        print("[RECOVER] 终止上次会话遗留进程组 pid=\(pid)")
    }
}
