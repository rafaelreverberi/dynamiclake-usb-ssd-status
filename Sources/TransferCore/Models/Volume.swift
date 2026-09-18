import Foundation

public enum VolumeKind: String, Codable, Sendable {
    case internalStorage
    case externalLocal
    case removable
    case network
    case diskImage
    case unknown
}

public struct Volume: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let mountURL: URL
    public let name: String
    public let uuid: String?
    public let fileSystemType: String?
    public let kind: VolumeKind
    public let isInternal: Bool?
    public let isLocal: Bool?
    public let isRemovable: Bool?
    public let isEjectable: Bool?
    public let isReadOnly: Bool?
    public let availableCapacity: Int64?
    public let totalCapacity: Int64?

    public init(
        id: String,
        mountURL: URL,
        name: String,
        uuid: String? = nil,
        fileSystemType: String? = nil,
        kind: VolumeKind,
        isInternal: Bool? = nil,
        isLocal: Bool? = nil,
        isRemovable: Bool? = nil,
        isEjectable: Bool? = nil,
        isReadOnly: Bool? = nil,
        availableCapacity: Int64? = nil,
        totalCapacity: Int64? = nil
    ) {
        self.id = id
        self.mountURL = mountURL
        self.name = name
        self.uuid = uuid
        self.fileSystemType = fileSystemType
        self.kind = kind
        self.isInternal = isInternal
        self.isLocal = isLocal
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.isReadOnly = isReadOnly
        self.availableCapacity = availableCapacity
        self.totalCapacity = totalCapacity
    }

    public var isRelevantExternal: Bool {
        kind == .externalLocal || kind == .removable
    }
}
