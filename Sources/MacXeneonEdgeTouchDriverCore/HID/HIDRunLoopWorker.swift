import Foundation

/// Owns the lifetime of a run loop independently of AppKit and the gesture queue.
/// Lifecycle calls are serialized by the owner (the application main thread).
final class HIDRunLoopWorker {
    private var runLoop: CFRunLoop?
    private var thread: Thread?

    func start(_ startup: @escaping () throws -> Void) throws {
        guard thread == nil else { return }
        let ready = DispatchSemaphore(value: 0)
        var startupError: Error?
        let worker = Thread {
            do {
                try startup()
                self.runLoop = CFRunLoopGetCurrent()
            } catch { startupError = error }
            ready.signal()
            if startupError == nil { CFRunLoopRun() }
        }
        worker.name = "Touch endpoint observation"
        worker.qualityOfService = .userInteractive
        thread = worker
        worker.start()
        ready.wait()
        if let startupError {
            thread = nil
            throw startupError
        }
    }

    func stop(_ cleanup: @escaping () -> Void) {
        guard let runLoop else { return }
        let finished = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
            cleanup()
            CFRunLoopStop(runLoop)
            finished.signal()
        }
        CFRunLoopWakeUp(runLoop)
        finished.wait()
        self.runLoop = nil
        thread = nil
    }
}
