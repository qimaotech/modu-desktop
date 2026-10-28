import Foundation
import Darwin

final class ProcessExitMonitor {
    private let queue: Int32

    init(_ pid: Int32) throws {
        queue = kqueue()
        guard queue >= 0 else { throw ModuError("update-helper-failed", .couldNotMonitorApplicationExit) }
        var event = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT), fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
        guard kevent(queue, &event, 1, nil, 0, nil) == 0 else {
            close(queue)
            throw ModuError("update-helper-failed", .couldNotMonitorRunningApplication)
        }
    }

    deinit { close(queue) }

    func exited() throws -> Bool {
        var event = kevent()
        var timeout = timespec(tv_sec: 0, tv_nsec: 0)
        let count = kevent(queue, nil, 0, &event, 1, &timeout)
        if count < 0, errno != EINTR { throw ModuError("update-helper-failed", .couldNotWaitForApplicationExit) }
        return count == 1
    }
}
