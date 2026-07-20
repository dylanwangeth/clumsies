import Foundation

enum JSONCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

struct EmptyPayload: Codable, Sendable {}

struct APIErrorPayload: Codable, Error, Equatable, Sendable {
    let code: String
    let message: String
    let requestId: String?
}
