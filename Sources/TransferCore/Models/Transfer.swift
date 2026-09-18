import Foundation

public enum TransferKind: String, Codable, Sendable {
    case copying
    case moving
    case receiving
    case uploading
    case downloading
    case fileActivity
}

public enum TransferState: String, Codable, Sendable {
    case preparing
    case active
    case indeterminate
    case completed
    case cancelled
    case failed
    case volumeDisconnected

    public var isActive: Bool {
        self == .preparing || self == .active || self == .indeterminate
    }
}

public enum TransferProviderKind: String, Codable, Sendable {
    case foundationProgress
    case finderAccessibility
    case fsevents

    public var priority: Int {
        switch self {
        case .foundationProgress: return 3
        case .finderAccessibility: return 2
        case .fsevents: return 1
        }
    }
}

public enum TransferConfidence: Int, Codable, Comparable, Sendable {
    case activity = 1
    case inferred = 2
    case exact = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct Transfer: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var kind: TransferKind
    public var state: TransferState
    public var sourceURL: URL?
    public var destinationURL: URL?
    public var sourceVolumeID: String?
    public var destinationVolumeID: String?
    public var volumeName: String?
    public var displayName: String
    public var currentFileName: String?
    public var fractionCompleted: Double?
    public var bytesCompleted: Int64?
    public var bytesTotal: Int64?
    public var filesCompleted: Int?
    public var filesTotal: Int?
    public var bytesPerSecond: Int64?
    public var estimatedSecondsRemaining: TimeInterval?
    public var startedAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    public var isCancellable: Bool
    public var isPausable: Bool
    public var provider: TransferProviderKind
    public var confidence: TransferConfidence
    public var failureDescription: String?

    public init(
        id: String,
        kind: TransferKind,
        state: TransferState,
        sourceURL: URL? = nil,
        destinationURL: URL? = nil,
        sourceVolumeID: String? = nil,
        destinationVolumeID: String? = nil,
        volumeName: String? = nil,
        displayName: String,
        currentFileName: String? = nil,
        fractionCompleted: Double? = nil,
        bytesCompleted: Int64? = nil,
        bytesTotal: Int64? = nil,
        filesCompleted: Int? = nil,
        filesTotal: Int? = nil,
        bytesPerSecond: Int64? = nil,
        estimatedSecondsRemaining: TimeInterval? = nil,
        startedAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil,
        isCancellable: Bool = false,
        isPausable: Bool = false,
        provider: TransferProviderKind,
        confidence: TransferConfidence,
        failureDescription: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.state = state
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.sourceVolumeID = sourceVolumeID
        self.destinationVolumeID = destinationVolumeID
        self.volumeName = volumeName
        self.displayName = displayName
        self.currentFileName = currentFileName
        self.fractionCompleted = fractionCompleted
        self.bytesCompleted = bytesCompleted
        self.bytesTotal = bytesTotal
        self.filesCompleted = filesCompleted
        self.filesTotal = filesTotal
        self.bytesPerSecond = bytesPerSecond
        self.estimatedSecondsRemaining = estimatedSecondsRemaining
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.isCancellable = isCancellable
        self.isPausable = isPausable
        self.provider = provider
        self.confidence = confidence
        self.failureDescription = failureDescription
    }
}

public enum TransferProviderEvent: Sendable {
    case updated(Transfer)
    case removed(id: String, finalState: TransferState)
}

public protocol TransferProviderDelegate: AnyObject {
    func transferProvider(_ provider: TransferProvider, emitted event: TransferProviderEvent)
}

public protocol TransferProvider: AnyObject {
    var name: String { get }
    var delegate: TransferProviderDelegate? { get set }
    func start(volumes: [Volume])
    func update(volumes: [Volume])
    func stop()
}
