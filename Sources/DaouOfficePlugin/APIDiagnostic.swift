import Foundation

/// Troubleshooting metadata only: schema, codes and a CAPTCHA status flag, never personal values.
public struct DaouOfficeAPIDiagnostic: Sendable, Equatable {
    public let path: String
    public let status: Int
    public let code: String?
    public let fields: [String]
    public let captchaRefreshRequired: Bool?
    init(path: String, data: Data, response: HTTPURLResponse) {
        self.path = path.replacingOccurrences(of: #"/\d+(?=/|$)"#, with: "/{id}", options: .regularExpression)
        status = response.statusCode
        let json = data.count <= 8 * 1_024 * 1_024 ? (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) : nil
        let rawCode = json?["code"] as? String
        code = rawCode?.range(of: #"^[A-Z0-9_-]{1,40}$"#, options: .regularExpression) != nil ? rawCode : nil
        let payload = json?["data"] as? [String: Any] ?? json ?? [:]
        if let flag = (json?["data"] as? [String: Any])?["needCaptchaRequest"] as? NSNumber,
           CFGetTypeID(flag) == CFBooleanGetTypeID() {
            captchaRefreshRequired = flag.boolValue
        } else { captchaRefreshRequired = nil }
        fields = payload.keys.filter { $0.range(of: #"^[A-Za-z][A-Za-z0-9_]{0,63}$"#, options: .regularExpression) != nil }.sorted().prefix(30).map { $0 }
    }
}
