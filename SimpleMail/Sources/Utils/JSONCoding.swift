import Foundation

/// Shared JSON coders for performance
/// Avoids allocating new coders for each encode/decode operation
enum JSONCoding {
    /// Shared decoder instance - thread-safe
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Shared encoder instance - thread-safe
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
