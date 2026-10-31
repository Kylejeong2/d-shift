import AppKit

/// Keeps one D-Shift running per user, whichever binary or worktree it was built from, so only one sidebar answers
/// Shift Shift. A second launch asks the running copy to show its sidebar and quits. `scripts/dev.sh` stops the
/// running copy first when it wants to replace it.
enum SingleInstance {
    /// `scripts/dev.sh` reads the running copy's pid from here, so keep the two in sync.
    private static let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent("dshift.lock")
    private static var signalSources: [DispatchSourceSignal] = []

    /// Exits if another copy is running. Otherwise holds the lock for the life of the process and calls
    /// `onRelaunch` whenever someone launches D-Shift again.
    static func claim(onRelaunch: @escaping @MainActor () -> Void) {
        let fd = open(lockURL.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else {
            Log.info("instance", "couldn't open \(lockURL.path); running without the single-instance check")
            return
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            var buffer = [CChar](repeating: 0, count: 32)
            if pread(fd, &buffer, buffer.count - 1, 0) > 0,
                let pid = pid_t(String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines))
            {
                kill(pid, SIGUSR1)
            }
            print("D-Shift is already running; showing its sidebar.")
            exit(0)
        }
        ftruncate(fd, 0)
        _ = "\(getpid())".withCString { write(fd, $0, strlen($0)) }
        // The descriptor stays open on purpose; the kernel releases the lock when the process exits.
        handle(SIGUSR1) { onRelaunch() }
        // SIGTERM's default action skips `applicationWillTerminate`, which would leave Codex runs behind.
        handle(SIGTERM) { NSApp.terminate(nil) }
    }

    private static func handle(_ signalNumber: Int32, _ action: @escaping @MainActor () -> Void) {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { action() } }
        source.resume()
        signalSources.append(source)
    }
}
