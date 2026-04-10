import Foundation
import WhisperDictationCore

let args = CommandLine.arguments
let configPath: String

if let configIndex = args.firstIndex(of: "--config"), args.indices.contains(configIndex + 1) {
    configPath = args[configIndex + 1]
} else {
    configPath = AppConfig.defaultConfigPath
}

do {
    let config = try AppConfig.load(from: configPath)
    let daemon = try WhisperDictationDaemon(config: config)
    try daemon.run()
} catch {
    fputs("whisper-dictation-daemon: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
