import Foundation

enum AttributedBodyDecoder {
    private static let marker = Data("NSString".utf8) + Data([0x00])
    private static let plusByte: UInt8 = 0x2B

    static func decode(_ data: Data?) -> String? {
        guard let data, let markerRange = data.range(of: marker) else { return nil }

        var index = markerRange.upperBound
        while index < data.count, data[index] != plusByte {
            index += 1
        }
        guard index < data.count else { return nil }

        index += 1
        guard index < data.count else { return nil }
        let prefix = data[index]
        index += 1

        let length: Int
        switch prefix {
        case 0x81:
            guard index + 1 <= data.count else { return nil }
            length = Int(data[index])
            index += 1
        case 0x82:
            guard index + 2 <= data.count else { return nil }
            length = Int(data[index]) | (Int(data[index + 1]) << 8)
            index += 2
        case 0x83:
            guard index + 3 <= data.count else { return nil }
            length = Int(data[index])
                | (Int(data[index + 1]) << 8)
                | (Int(data[index + 2]) << 16)
            index += 3
        default:
            length = Int(prefix)
        }

        guard index + length <= data.count else { return nil }
        return String(data: data[index..<(index + length)], encoding: .utf8)
    }
}
