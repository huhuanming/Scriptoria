import Foundation

/// Utilities for managing running processes
public enum ProcessManager {
    /// Check if a process with the given PID is still running
    public static func isRunning(pid: Int32) -> Bool {
        // kill with signal 0 checks existence without sending a signal
        return kill(pid, 0) == 0
    }

    /// Terminate a process. Returns true if signal was sent successfully.
    public static func terminate(pid: Int32, force: Bool = false) -> Bool {
        let signal: Int32 = force ? SIGKILL : SIGTERM
        return kill(pid, signal) == 0
    }

    /// Find DB records with status=running but dead PIDs, and mark them as failed
    public static func cleanStaleRuns(store: ScriptStore) {
        guard let runs = try? store.fetchRunningRuns() else { return }
        for var run in runs {
            let isAlive: Bool
            if let pid = run.pid {
                isAlive = isRunning(pid: pid)
            } else {
                // No PID recorded — assume stale
                isAlive = false
            }

            if !isAlive {
                run.status = .failure
                run.finishedAt = Date()
                try? store.updateRunHistorySync(run)
            }
        }
    }
}
