import Foundation
import TransferCore

private var retainedProbe: ProgressProbe?
private var retainedSignal: DispatchSourceSignal?

@main
private enum Main {
    static func main() {
        let probe = ProgressProbe()
        retainedProbe = probe
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler { probe.stop(); exit(0) }
        source.resume()
        retainedSignal = source
        probe.start()
        print("Transfer Probe is running. Start a Finder copy involving a mounted external drive. Press Ctrl-C to stop.")
        RunLoop.main.run()
    }
}
