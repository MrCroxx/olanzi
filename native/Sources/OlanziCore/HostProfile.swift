import Foundation

public struct HostProfile: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var version: Int = 2
    public var name: String
    public var keymap: HostKeymap

    public init(name: String, keymap: HostKeymap) {
        id = UUID()
        self.name = name
        self.keymap = keymap
    }

    public func validate() throws {
        guard version == 2 else { throw HostKeymapError.unsupportedVersion }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80 else {
            throw HostKeymapError.invalidName
        }
        try keymap.validate()
    }

    public static func decode(data: Data) throws -> HostProfile {
        guard data.count <= HostKeymap.maximumJSONBytes else { throw HostKeymapError.tooLarge }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    private enum CodingKeys: String, CodingKey { case id, version, name, keymap, codes }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        let sourceVersion = try values.decode(Int.self, forKey: .version)
        switch sourceVersion {
        case 1:
            // 旧版只记录六个单键；迁移时保留标识、名称，不擅自增加手势。
            let codes = try values.decode([UInt8].self, forKey: .codes)
            keymap = try HostKeymap.fromDeviceBindings(codes.enumerated().map {
                KeyBinding(index: $0.offset, entries: [KeyEntry(code: $0.element)])
            })
        case 2:
            keymap = try values.decode(HostKeymap.self, forKey: .keymap)
        default: throw HostKeymapError.unsupportedVersion
        }
        version = 2
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(2, forKey: .version)
        try values.encode(name, forKey: .name)
        try values.encode(keymap, forKey: .keymap)
    }
}
