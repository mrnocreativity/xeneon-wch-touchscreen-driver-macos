import Darwin
import Foundation
import MacXeneonEdgeTouchDriverCore

@main
struct MacXeneonEdgeTouchDriverMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if !arguments.isEmpty {
            guard arguments.count == 1,
                  ["status", "re-pair", "cancel-pairing"].contains(arguments[0]) else {
                print("Usage: MacXeneonEdgeTouchDriver [status | re-pair | cancel-pairing]")
                exit(arguments == ["--help"] ? EXIT_SUCCESS : EXIT_FAILURE)
            }
            do {
                let reply = try DriverControl.request(arguments[0])
                print(reply)
                exit(reply.contains("\"error\"") ? EXIT_FAILURE : EXIT_SUCCESS)
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exit(EXIT_FAILURE)
            }
        }
        let loadResult = DriverConfiguration.load()
        do {
            try DriverFileLog.shared.configure(
                fileLogPath: loadResult.configuration.diagnostics.fileLogPath,
                maxBytes: loadResult.configuration.diagnostics.fileLogMaxBytes,
                minimumLevel: DriverLogLevel(configurationName: loadResult.configuration.logLevel) ?? .notice
            )
        } catch {
            DriverLoggers.log(.error, category: .lifecycle, "Could not configure diagnostics file logging: \(error.localizedDescription)")
        }

        for warning in loadResult.warnings {
            DriverLoggers.log(.warning, category: .lifecycle, warning)
        }

        let application = MacXeneonEdgeTouchDriverApplication(configuration: loadResult.configuration)
        exit(application.run())
    }
}
