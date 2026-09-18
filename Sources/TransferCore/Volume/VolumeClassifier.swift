import DiskArbitration
import Foundation

public struct VolumeResourceSnapshot: Sendable {
    public var mountURL: URL
    public var name: String?
    public var uuid: String?
    public var fileSystemType: String?
    public var isInternal: Bool?
    public var isLocal: Bool?
    public var isRemovable: Bool?
    public var isEjectable: Bool?
    public var isReadOnly: Bool?
    public var availableCapacity: Int64?
    public var totalCapacity: Int64?
    public var deviceProtocol: String?

    public init(
        mountURL: URL,
        name: String? = nil,
        uuid: String? = nil,
        fileSystemType: String? = nil,
        isInternal: Bool? = nil,
        isLocal: Bool? = nil,
        isRemovable: Bool? = nil,
        isEjectable: Bool? = nil,
        isReadOnly: Bool? = nil,
        availableCapacity: Int64? = nil,
        totalCapacity: Int64? = nil,
        deviceProtocol: String? = nil
    ) {
        self.mountURL = mountURL
        self.name = name
        self.uuid = uuid
        self.fileSystemType = fileSystemType
        self.isInternal = isInternal
        self.isLocal = isLocal
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.isReadOnly = isReadOnly
        self.availableCapacity = availableCapacity
        self.totalCapacity = totalCapacity
        self.deviceProtocol = deviceProtocol
    }
}

public enum VolumeClassifier {
    public static func classify(_ snapshot: VolumeResourceSnapshot) -> VolumeKind {
        let deviceProtocol = snapshot.deviceProtocol?.lowercased() ?? ""
        if deviceProtocol.contains("disk image") || deviceProtocol.contains("virtual") {
            return .diskImage
        }
        if snapshot.isLocal == false { return .network }
        if snapshot.isInternal == true { return .internalStorage }
        if snapshot.isRemovable == true { return .removable }
        if snapshot.isInternal == false && (snapshot.isEjectable == true || snapshot.isLocal == true) {
            return .externalLocal
        }
        return .unknown
    }

    public static func makeVolume(from snapshot: VolumeResourceSnapshot) -> Volume {
        let standardizedURL = snapshot.mountURL.standardizedFileURL
        let stableID = snapshot.uuid ?? standardizedURL.path
        return Volume(
            id: stableID,
            mountURL: standardizedURL,
            name: snapshot.name ?? standardizedURL.lastPathComponent,
            uuid: snapshot.uuid,
            fileSystemType: snapshot.fileSystemType,
            kind: classify(snapshot),
            isInternal: snapshot.isInternal,
            isLocal: snapshot.isLocal,
            isRemovable: snapshot.isRemovable,
            isEjectable: snapshot.isEjectable,
            isReadOnly: snapshot.isReadOnly,
            availableCapacity: snapshot.availableCapacity,
            totalCapacity: snapshot.totalCapacity
        )
    }
}

enum VolumeMetadataReader {
    static let keys: Set<URLResourceKey> = [
        .volumeLocalizedNameKey,
        .volumeUUIDStringKey,
        .volumeLocalizedFormatDescriptionKey,
        .volumeIsInternalKey,
        .volumeIsLocalKey,
        .volumeIsRemovableKey,
        .volumeIsEjectableKey,
        .volumeIsReadOnlyKey,
        .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeTotalCapacityKey,
    ]

    static func snapshot(for url: URL) -> VolumeResourceSnapshot? {
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        return VolumeResourceSnapshot(
            mountURL: url,
            name: values.volumeLocalizedName,
            uuid: values.volumeUUIDString,
            fileSystemType: values.volumeLocalizedFormatDescription,
            isInternal: values.volumeIsInternal,
            isLocal: values.volumeIsLocal,
            isRemovable: values.volumeIsRemovable,
            isEjectable: values.volumeIsEjectable,
            isReadOnly: values.volumeIsReadOnly,
            availableCapacity: VolumeCapacityResolver.available(
                raw: values.volumeAvailableCapacity,
                importantUsage: values.volumeAvailableCapacityForImportantUsage
            ),
            totalCapacity: values.volumeTotalCapacity.map(Int64.init),
            deviceProtocol: diskProtocol(for: url)
        )
    }

    private static func diskProtocol(for url: URL) -> String? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let description = DADiskCopyDescription(disk) as? [String: Any] else { return nil }
        return description[kDADiskDescriptionDeviceProtocolKey as String] as? String
    }
}

enum VolumeCapacityResolver {
    static func available(raw: Int?, importantUsage: Int64?) -> Int64? {
        raw.map(Int64.init) ?? importantUsage
    }
}
