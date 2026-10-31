import AppKit

/// Keeps one D-Shift running per user, whichever binary or worktree it was built from, so only one sidebar answers
/// Shift Shift. The newest launch wins: it asks the running copy to quit, then takes the lock.
enum SingleInstance {
    private static let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent("dshift.lock")
    private static var terminationSource: DispatchSourceSignal?

    static func claim() {
        let fd = open(lockURL.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else {
            Log.info("instance", "couldn't open \(lockURL.path); running without the single-instance check")
            return
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            replaceRunningInstance(lockedBy: fd)
        }
        ftruncate(fd, 0)
        _ = "\(getpid())".withCString { write(fd, $0, strlen($0)) }
        // The descriptor stays open for the life of the process; the kernel releases the lock when it exits.
        quitOnTerminationSignal()
    }

    private static func replaceRunningInstance(lockedBy fd: Int32) {
        var buffer = [CChar](repeating: 0, count: 32)
        let count = pread(fd, &buffer, buffer.count - 1, 0)
        guard count > 0, let pid = pid_t(String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            flock(fd, LOCK_EX)
            return
        }
        Log.info("instance", "replacing running D-Shift (pid \(pid))")
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(3)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if Date() > deadline {
                kill(pid, SIGKILL)
                flock(fd, LOCK_EX)
                return
            }
            usleep(50_000)
        }
    }

    /// SIGTERM's default action skips `applicationWillTerminate`, which would leave Codex runs behind.
    private static func quitOnTerminationSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        source.resume()
        terminationSource = source
    }
}
