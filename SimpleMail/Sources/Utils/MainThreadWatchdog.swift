import Foundation
import os.signpost

enum MainThreadWatchdog {
    private static let log = OSLog(subsystem: "com.simplemail.app", category: "Watchdog")
    private static var timer: DispatchSourceTimer?

    static func start(thresholdMs: Int = 300) {
        stop()
        let queue = DispatchQueue(label: "watchdog", qos: .background)
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer?.schedule(deadline: .now(), repeating: .milliseconds(500))
        timer?.setEventHandler {
            let start = DispatchTime.now()
            DispatchQueue.main.async {
                let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
                let ms = Int(Double(elapsed) / 1_000_000.0)
                if ms > thresholdMs {
                    os_log("Main thread stall %d ms", log: log, type: .error, ms)
                }
            }
        }
        timer?.resume()
    }

    static func stop() {
        timer?.cancel()
        timer = nil
    }
}
