import Foundation
import ImageIO
import AppPluginCore

/// A short-lived image for a person to answer. It is never persisted or included in diagnostics.
public struct DaouOfficeCaptchaChallenge: Sendable, Equatable {
    public let id: UUID
    public let imageData: Data

    init(data: Data) throws {
        guard let payload = try DaouOfficeAPIParser.payload(data) as? [String: Any],
              let encoded = payload["captchaImage"] as? String,
              encoded.utf8.count <= 700_000,
              let image = Data(base64Encoded: encoded), image.count <= 512 * 1_024,
              image.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              let source = CGImageSourceCreateWithData(image as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...2_048).contains(width), (1...2_048).contains(height),
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            throw PluginFailure.unsupportedResponse
        }
        id = UUID(); imageData = image
    }
}

/// Cancellation also discards the credential retained only for a pending human sign-in.
final class DaouOfficeCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var password: String?
    var isCancelled: Bool { lock.withLock { cancelled } }
    var retainedPassword: String? { lock.withLock { cancelled ? nil : password } }
    func retainPassword(_ value: String) throws {
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            password = value
        }
    }
    func discardPassword() { lock.withLock { password = nil } }
    func cancel() { lock.withLock { cancelled = true; password = nil } }
}
