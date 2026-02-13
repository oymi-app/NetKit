import Foundation
import Logger

private let netKitLogger = DefaultLogger(
    subsystem: LogSubsystem(
        identifier: "dev.bonzer.netKit",
        category: "🕸 Networking"
    ))

func log(message: String) {
    netKitLogger.log(message)
}
