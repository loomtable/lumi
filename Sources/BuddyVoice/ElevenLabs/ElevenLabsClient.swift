import BuddyCore
import Foundation
import os

/// One HTTP exchange whose body arrives in pieces: URLSession in the app, a script in tests.
public protocol HTTPStreamer: Sendable {
    func send(_ request: URLRequest) async throws -> (status: Int, body: AsyncThrowingStream<Data, any Error>)
}

/// URLSession's byte stream, regrouped into chunks (100 ms of 24 kHz 16-bit audio each).
public struct URLSessionStreamer: HTTPStreamer {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (status: Int, body: AsyncThrowingStream<Data, any Error>) {
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, Self.chunks(bytes))
    }

    static let chunkBytes = 4_800

    private static func chunks(_ bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            let reader = Task {
                do {
                    var chunk = Data(capacity: chunkBytes)
                    for try await byte in bytes {
                        chunk.append(byte)
                        if chunk.count >= chunkBytes {
                            continuation.yield(chunk)
                            chunk = Data(capacity: chunkBytes)
                        }
                    }
                    if !chunk.isEmpty { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Stopping the reply drops the stream, which cancels the read and with it the request.
            continuation.onTermination = { _ in reader.cancel() }
        }
    }
}

/// Why ElevenLabs didn't speak. The account problems keep the on-device voice until the key changes;
/// the others only affect the reply they happened on.
public enum ElevenLabsFailure: Error, Equatable, Sendable {
    case noKey
    /// The Keychain wouldn't give the key back (a denied prompt, a locked keychain).
    case keyUnreadable
    case invalidKey
    /// The key works but lacks a permission this call needs (e.g. reading voices).
    case missingPermission
    case quotaExceeded
    case modelRejected(String)
    case unreachable(String)
    case badResponse(status: Int)

    public var isAccountProblem: Bool {
        switch self {
        case .noKey, .keyUnreadable, .invalidKey, .quotaExceeded: true
        default: false
        }
    }
}

public struct ElevenLabsVoice: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let category: String?

    public init(id: String, name: String, category: String?) {
        self.id = id
        self.name = name
        self.category = category
    }
}

/// ElevenLabs' REST API: streaming text to speech as raw 24 kHz PCM, and the voice list.
/// The key is read from `keys` per request and only ever sent in the `xi-api-key` header; neither the
/// key nor the text is logged.
public actor ElevenLabsClient {
    /// Eleven v4 Turbo: the real-time model.
    public static let model = "eleven_v4_turbo"
    /// Used if the stream endpoint rejects v4 Turbo: the documented low-latency streaming model.
    static let fallbackModel = "eleven_flash_v2_5"
    public static let sampleRate = 24_000.0
    static let base = URL(string: "https://api.elevenlabs.io")!
    /// Seconds without a byte before the request fails (URLRequest's idle timeout).
    static let timeout: TimeInterval = 5

    private let http: any HTTPStreamer
    private let keys: any SecretStore
    private(set) var model = ElevenLabsClient.model
    private let log = Logger(subsystem: BuddyCore.bundleIdentifier, category: "voice")

    public init(http: any HTTPStreamer = URLSessionStreamer(), keys: any SecretStore = CachedSecretStore.elevenLabs) {
        self.http = http
        self.keys = keys
    }

    /// The stored key, or `.noKey`.
    func key() throws -> String {
        let stored: String?
        do { stored = try keys.read() } catch { throw ElevenLabsFailure.keyUnreadable }
        guard let key = stored, !key.isEmpty else { throw ElevenLabsFailure.noKey }
        return key
    }

    /// Speech for `text` as Float samples at `sampleRate`, delivered as it streams in.
    public func speech(_ text: String, voiceID: String) async throws -> AsyncThrowingStream<[Float], any Error> {
        let key = try key()
        do {
            return try await stream(text, voiceID: voiceID, key: key, model: model)
        } catch ElevenLabsFailure.modelRejected(let detail) where model != Self.fallbackModel {
            log.error("ElevenLabs rejected \(self.model, privacy: .public) (\(detail, privacy: .public)); using \(Self.fallbackModel, privacy: .public)")
            model = Self.fallbackModel
            return try await stream(text, voiceID: voiceID, key: key, model: model)
        }
    }

    /// The account's voices. With `key`, checks that key instead of the stored one.
    public func voices(key: String? = nil) async throws -> [ElevenLabsVoice] {
        let key = try key ?? self.key()
        var request = URLRequest(url: Self.base.appending(path: "v1/voices"), timeoutInterval: Self.timeout)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        let body = try await collect(request)
        struct List: Decodable {
            struct Voice: Decodable { let voice_id: String; let name: String; let category: String? }
            let voices: [Voice]
        }
        guard let list = try? JSONDecoder().decode(List.self, from: body) else { throw ElevenLabsFailure.badResponse(status: 200) }
        return list.voices.map { ElevenLabsVoice(id: $0.voice_id, name: $0.name, category: $0.category) }
    }

    private func stream(_ text: String, voiceID: String, key: String, model: String) async throws -> AsyncThrowingStream<[Float], any Error> {
        var url = Self.base.appending(path: "v1/text-to-speech").appending(path: voiceID).appending(path: "stream")
        url.append(queryItems: [URLQueryItem(name: "output_format", value: "pcm_24000")])
        var request = URLRequest(url: url, timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["text": text, "model_id": model])
        let (status, body) = try await send(request)
        guard status == 200 else { throw Self.failure(status: status, body: try await Self.drain(body, limit: 64_000)) }
        return Self.samples(body)
    }

    private func collect(_ request: URLRequest) async throws -> Data {
        let (status, body) = try await send(request)
        // The voice list runs to hundreds of KB (previews, languages); only error bodies are capped.
        let data = try await Self.drain(body, limit: status == 200 ? 16_000_000 : 64_000)
        guard status == 200 else { throw Self.failure(status: status, body: data) }
        return data
    }

    private func send(_ request: URLRequest) async throws -> (status: Int, body: AsyncThrowingStream<Data, any Error>) {
        do {
            return try await http.send(request)
        } catch let error as URLError {
            throw ElevenLabsFailure.unreachable(error.code == .timedOut ? "timed out" : "offline or unreachable")
        }
    }

    private static func drain(_ body: AsyncThrowingStream<Data, any Error>, limit: Int) async throws -> Data {
        var data = Data()
        do {
            for try await chunk in body where data.count < limit { data.append(chunk) }
        } catch {
            throw ElevenLabsFailure.unreachable("connection dropped")
        }
        return data
    }

    /// Maps an error response to a failure. ElevenLabs sends `{"detail": {"status", "message"}}`, but a
    /// validation error's `detail` can be a string or a list, so the raw text is searched as well.
    static func failure(status: Int, body: Data) -> ElevenLabsFailure {
        let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let code = ((json?["detail"] as? [String: Any])?["status"] as? String ?? "").lowercased()
        let text = String(decoding: body.prefix(8_000), as: UTF8.self).lowercased()
        if text.contains("quota") || (code.contains("limit_exceeded") && !code.contains("character")) { return .quotaExceeded }
        if code == "missing_permissions" { return .missingPermission }
        switch status {
        case 401, 403: return .invalidKey
        case 400, 404, 422:
            return text.contains("model") ? .modelRejected(code.isEmpty ? "status \(status)" : code) : .badResponse(status: status)
        case 429: return .unreachable("busy")
        case 500...: return .unreachable("server error \(status)")
        default: return .badResponse(status: status)
        }
    }

    /// Raw 16-bit little-endian mono PCM to Float samples, keeping an odd byte for the next chunk.
    static func samples(_ body: AsyncThrowingStream<Data, any Error>) -> AsyncThrowingStream<[Float], any Error> {
        AsyncThrowingStream { continuation in
            let decoder = Task {
                var carry = Data()
                do {
                    for try await chunk in body {
                        let floats = decode(chunk, carry: &carry)
                        if !floats.isEmpty { continuation.yield(floats) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: ElevenLabsFailure.unreachable("connection dropped"))
                }
            }
            continuation.onTermination = { _ in decoder.cancel() }
        }
    }

    static func decode(_ chunk: Data, carry: inout Data) -> [Float] {
        var bytes = carry
        bytes.append(chunk)
        let usable = bytes.count & ~1
        carry = usable < bytes.count ? Data(bytes.suffix(1)) : Data()
        var out = [Float](repeating: 0, count: usable / 2)
        bytes.withUnsafeBytes { raw in
            for i in 0 ..< usable / 2 {
                let lo = UInt16(raw[2 * i]), hi = UInt16(raw[2 * i + 1])
                out[i] = Float(Int16(bitPattern: lo | hi << 8)) / 32_768
            }
        }
        return out
    }
}
