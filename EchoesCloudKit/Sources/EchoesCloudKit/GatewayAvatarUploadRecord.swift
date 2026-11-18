import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum GatewayAvatarUploadJournalFailure: Error, Equatable, Sendable, LocalizedError {
    case inactive, unavailable, invalidData, capacity, busy, pendingExists, superseded, sourceUnavailable,
        invalidTransition
    public var errorDescription: String? {
        switch self {
        case .inactive, .superseded: "Konto lub dostęp do operacji zdjęcia zmieniły się."
        case .unavailable, .invalidData: "Nie udało się bezpiecznie odczytać lub zapisać operacji zdjęcia."
        case .capacity, .busy: "Magazyn operacji zdjęcia jest niedostępny. Spróbuj ponownie."
        case .pendingExists: "Najpierw sprawdź wynik poprzedniej operacji zdjęcia."
        case .sourceUnavailable: "Lokalna kopia zdjęcia jest niedostępna. Zachowano identyfikatory operacji."
        case .invalidTransition: "Najpierw odśwież stan operacji zdjęcia."
        }
    }
}
public struct GatewayAvatarUploadScope: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    let privateScope: PrivateAccountScope
    let binding: GatewayIdentityBinding
    let digest: String
    public init(
        configuration: GatewayConfiguration, privateScope: PrivateAccountScope,
        binding: GatewayIdentityBinding
    ) throws {
        let community = try GatewayCommunityScope(
            configuration: configuration, privateScope: privateScope, binding: binding)
        self.privateScope = privateScope
        self.binding = binding
        digest = communityDigest("echoes/avatar-upload-scope/v1\0" + community.digest)
    }
    public var description: String { "GatewayAvatarUploadScope(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public struct GatewayAvatarUploadJournalLease: Sendable, CustomStringConvertible, CustomReflectable {
    let id: String
    let scope: GatewayAvatarUploadScope
    public var description: String { "GatewayAvatarUploadJournalLease(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public enum GatewayAvatarJournalIntent: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    case upload(GatewayAvatarUploadIntent)
    case publish(GatewayAvatarPublishIntent)
    case clear(requestID: String, expectedGeneration: Int)
    public var description: String { "GatewayAvatarJournalIntent(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public enum GatewayAvatarJournalPhase: String, Codable, Sendable {
    case prepared, dispatched, staged, publishing
}
public struct GatewayAvatarUploadJournalEntry: Equatable, Sendable, CustomStringConvertible, CustomReflectable
{
    let revision: String
    public let intent: GatewayAvatarJournalIntent
    public let phase: GatewayAvatarJournalPhase
    public let createdAt: Date
    public let hasSource: Bool
    public let sourceByteCount: Int?
    public let sourceSHA256: String?
    public var description: String { "GatewayAvatarUploadJournalEntry(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

extension GatewayAvatarUploadJournalEntry {
    /// A fresh, exact terminal server result allows explicit local forgetting, never a new dispatch.
    func isExpired(by snapshot: GatewayAvatarOwnerSnapshot) -> Bool {
        guard snapshot.status == .expired else { return false }
        switch intent {
        case .upload(let selected):
            return snapshot.requestID == selected.requestID && snapshot.versionID == selected.versionID
                && snapshot.generation == selected.expectedGeneration + 1
        case .publish(let selected): return selected.matches(snapshot)
        case .clear: return false
        }
    }
}

struct StoredAvatarUpload: Codable {
    var revision: String, kind: String, requestID: String
    var expectedGeneration: Int
    var phase: GatewayAvatarJournalPhase
    var createdAt: Double
    var versionID: String?, consentVersion: Int?, sourceSHA256: String?, sourceByteCount: Int?, width: Int?,
        height: Int?
    var sourcePresent: Bool?
    var reviewRevision: String?
    func intent() throws -> GatewayAvatarJournalIntent {
        if kind == "upload", let versionID, let consentVersion {
            return .upload(
                try .init(
                    requestID: requestID, versionID: versionID, expectedGeneration: expectedGeneration,
                    consentVersion: consentVersion))
        }
        if kind == "publish", let versionID, let reviewRevision, let consentVersion {
            return .publish(
                try .init(
                    requestID: requestID, versionID: versionID,
                    generation: expectedGeneration, reviewRevision: reviewRevision,
                    consentVersion: consentVersion))
        }
        guard kind == "clear", gatewayUUID(requestID),
            (0..<9_007_199_254_740_991).contains(expectedGeneration)
        else {
            throw GatewayAvatarUploadJournalFailure.invalidData
        }
        return .clear(requestID: requestID, expectedGeneration: expectedGeneration)
    }
    func entry() throws -> GatewayAvatarUploadJournalEntry {
        try .init(
            revision: revision, intent: intent(), phase: phase,
            createdAt: Date(timeIntervalSince1970: createdAt),
            hasSource: sourcePresent == true, sourceByteCount: sourceByteCount, sourceSHA256: sourceSHA256)
    }
}
struct StoredAvatarUploadRecord: Codable {
    let schemaVersion: Int, privateScope: String, scope: String
    var lease: String
    var entry: StoredAvatarUpload?
}
struct AvatarUploadEnvelope {
    var record: StoredAvatarUploadRecord
    var source: Data
}
enum AvatarUploadRecordCodec {
    static let maximumFileBytes = 262144
    static let sourceLifetime: Double = 7 * 86400
    static let magic = Data("ECHOESAVATARUPLOAD1\n".utf8)
    static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    static func image(_ bytes: Data) throws -> (width: Int, height: Int) {
        try Task.checkCancellation()
        guard (4...256000).contains(bytes.count), bytes.starts(with: [0xff, 0xd8]),
            bytes.suffix(2).elementsEqual([0xff, 0xd9]),
            let source = CGImageSourceCreateWithData(
                bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetCount(source) == 1,
            CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
            let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
            (1...512).contains(width.intValue), (1...512).contains(height.intValue),
            properties[kCGImagePropertyGPSDictionary] == nil,
            properties[kCGImagePropertyTIFFDictionary] == nil,
            properties[kCGImagePropertyIPTCDictionary] == nil,
            (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1 == 1,
            CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
                != nil
        else { throw GatewayAvatarUploadJournalFailure.invalidData }
        // ImageIO itself adds these three nonpersonal fields when AvatarPreparer encodes sRGB.
        // Camera/date/comment fields are not accepted as part of that generated dictionary.
        if let raw = properties[kCGImagePropertyExifDictionary] {
            guard let exif = raw as? [String: Any] else {
                throw GatewayAvatarUploadJournalFailure.invalidData
            }
            let generated = [
                kCGImagePropertyExifColorSpace as String: 1,
                kCGImagePropertyExifPixelXDimension as String: width.intValue,
                kCGImagePropertyExifPixelYDimension as String: height.intValue,
            ]
            guard Set(exif.keys).isSubset(of: Set(generated.keys)) else {
                throw GatewayAvatarUploadJournalFailure.invalidData
            }
            for (key, value) in exif {
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                    number.doubleValue == Double(generated[key]!)
                else { throw GatewayAvatarUploadJournalFailure.invalidData }
            }
        }
        return (width.intValue, height.intValue)
    }
    static func encode(_ value: AvatarUploadEnvelope) throws -> Data {
        let json = try JSONEncoder().encode(value.record)
        guard (1...4096).contains(json.count), value.source.count <= 256000 else {
            throw GatewayAvatarUploadJournalFailure.invalidData
        }
        let count = UInt32(json.count)
        var result = magic
        result.append(contentsOf: [
            UInt8(count >> 24), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255),
        ])
        result.append(json)
        result.append(value.source)
        guard result.count <= maximumFileBytes else { throw GatewayAvatarUploadJournalFailure.invalidData }
        return result
    }
    static func decode(_ bytes: Data, scope: GatewayAvatarUploadScope) throws -> AvatarUploadEnvelope {
        do {
            guard bytes.count <= maximumFileBytes, bytes.starts(with: magic), bytes.count > magic.count + 4
            else {
                throw GatewayAvatarUploadJournalFailure.invalidData
            }
            let count = bytes[magic.count..<(magic.count + 4)].reduce(0) { $0 * 256 + Int($1) }
            let start = magic.count + 4
            guard (1...4096).contains(count), bytes.count >= start + count else {
                throw GatewayAvatarUploadJournalFailure.invalidData
            }
            let json = bytes.subdata(in: start..<(start + count))
            guard let raw = try JSONSerialization.jsonObject(with: json) as? [String: Any],
                Set(raw.keys)
                    == Set(
                        ["schemaVersion", "privateScope", "scope", "lease"]
                            + (raw["entry"] == nil ? [] : ["entry"]))
            else { throw GatewayAvatarUploadJournalFailure.invalidData }
            let record = try JSONDecoder().decode(StoredAvatarUploadRecord.self, from: json)
            let source = bytes.subdata(in: (start + count)..<bytes.count)
            guard record.schemaVersion == 1, record.privateScope == scope.privateScope.digest,
                record.scope == scope.digest, gatewayUUID(record.lease)
            else {
                throw GatewayAvatarUploadJournalFailure.invalidData
            }
            if let entry = record.entry {
                guard let item = raw["entry"] as? [String: Any] else {
                    throw GatewayAvatarUploadJournalFailure.invalidData
                }
                let base = ["revision", "kind", "requestID", "expectedGeneration", "phase", "createdAt"]
                let fields =
                    base
                    + (entry.kind == "upload"
                        ? [
                            "versionID", "consentVersion", "sourceSHA256", "sourceByteCount", "width",
                            "height", "sourcePresent",
                        ] : entry.kind == "publish" ? ["versionID", "reviewRevision", "consentVersion"] : [])
                guard Set(item.keys) == Set(fields), gatewayUUID(entry.revision), entry.createdAt.isFinite,
                    entry.createdAt >= 0,
                    entry.createdAt < 9_007_199_254_740
                else { throw GatewayAvatarUploadJournalFailure.invalidData }
                _ = try entry.intent()
                if entry.kind == "upload" {
                    guard let hash = entry.sourceSHA256, GatewayAvatarQuery.validDigest(hash),
                        let length = entry.sourceByteCount,
                        (4...256000).contains(length), let width = entry.width, let height = entry.height,
                        (1...512).contains(width), (1...512).contains(height),
                        let present = entry.sourcePresent, present ? source.count == length : source.isEmpty
                    else { throw GatewayAvatarUploadJournalFailure.invalidData }
                    if present {
                        guard digest(source) == hash else {
                            throw GatewayAvatarUploadJournalFailure.invalidData
                        }
                        let actual = try image(source)
                        guard actual.width == width, actual.height == height else {
                            throw GatewayAvatarUploadJournalFailure.invalidData
                        }
                    }
                } else if entry.kind == "publish" {
                    guard source.isEmpty, entry.phase == .prepared || entry.phase == .publishing else {
                        throw GatewayAvatarUploadJournalFailure.invalidData
                    }
                } else {
                    guard source.isEmpty, entry.phase == .prepared || entry.phase == .dispatched else {
                        throw GatewayAvatarUploadJournalFailure.invalidData
                    }
                }
            } else {
                guard raw["entry"] == nil, source.isEmpty else {
                    throw GatewayAvatarUploadJournalFailure.invalidData
                }
            }
            return .init(record: record, source: source)
        } catch is CancellationError { throw CancellationError() } catch {
            throw GatewayAvatarUploadJournalFailure.invalidData
        }
    }
}
