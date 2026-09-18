import AppKit
import Foundation

public enum EjectError: LocalizedError {
    case notEjectable
    case transferActive
    case activityUncertain
    case system(Error)

    public var errorDescription: String? {
        switch self {
        case .notEjectable: return "This volume is not ejectable."
        case .transferActive: return "The drive cannot be ejected while a known transfer is active."
        case .activityUncertain: return "Recent write activity has not settled, so eject was not attempted."
        case .system(let error): return "macOS refused to eject the drive: \(error.localizedDescription)"
        }
    }
}

public final class EjectService {
    private let isTransferActive: (String) -> Bool
    private let hasRecentWriteActivity: (String) -> Bool

    public init(
        isTransferActive: @escaping (String) -> Bool,
        hasRecentWriteActivity: @escaping (String) -> Bool = { _ in false }
    ) {
        self.isTransferActive = isTransferActive
        self.hasRecentWriteActivity = hasRecentWriteActivity
    }

    public func eject(_ volume: Volume, completion: @escaping (Result<Void, EjectError>) -> Void) {
        guard volume.isEjectable == true else { completion(.failure(.notEjectable)); return }
        guard !isTransferActive(volume.id) else { completion(.failure(.transferActive)); return }
        guard !hasRecentWriteActivity(volume.id) else { completion(.failure(.activityUncertain)); return }

        DispatchQueue.main.async {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: volume.mountURL)
                completion(.success(()))
            } catch {
                completion(.failure(.system(error)))
            }
        }
    }
}
