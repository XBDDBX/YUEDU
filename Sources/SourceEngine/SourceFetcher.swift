import Foundation
import SwiftSoup

enum FetchError: LocalizedError {
    case badURL
    case http(Int)
    case empty
    case decode
    case timeout
    case network

    var errorDescription: String? {
        switch self {
        case .badURL: return "链接无效"
        case .http(let code): return "服务器返回 \(code)"
        case .empty: return "内容为空"
        case .decode: return "页面解码失败"
        case .timeout: return "请求超时（站点慢或需登录，可在书源里配置 header/登录）"
        case .network: return "网络连接失败"
        }
    }
}

enum SourceFetcher {
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

    static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 35
        cfg.httpAdditionalHeaders = [
            "User-Agent": userAgent,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8"
        ]
        return URLSession(configuration: cfg)
    }()

    static func data(_ urlString: String, headers: [String: String] = [:], method: String = "GET", body: Data? = nil) async throws -> Data {
        guard let url = URL(string: urlString), url.scheme != nil else { throw FetchError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if req.value(forHTTPHeaderField: "User-Agent") == nil {
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }

        do {
            let (data, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200...399).contains(http.statusCode) {
                throw FetchError.http(http.statusCode)
            }
            if data.isEmpty { throw FetchError.empty }
            return data
        } catch let e as FetchError {
            throw e
        } catch let e as URLError {
            if e.code == .timedOut { throw FetchError.timeout }
            throw FetchError.network
        }
    }

    static func html(_ urlString: String, headers: [String: String] = [:]) async throws -> Document {
        let d = try await data(urlString, headers: headers)
        let text = decode(d, contentType: nil)
        return try SwiftSoup.parse(text, urlString)
    }

    static func html(_ urlString: String, headers: [String: String], method: String, body: Data?) async throws -> Document {
        let d = try await data(urlString, headers: headers, method: method, body: body)
        let text = decode(d, contentType: nil)
        return try SwiftSoup.parse(text, urlString)
    }

    /// 中文站点常见的 GBK / GB18030 兜底
    static func decode(_ data: Data, contentType: String?) -> String {
        if let ct = contentType, let r = ct.range(of: "charset=", options: .caseInsensitive) {
            let cs = ct[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " \"';"))
            let enc = CFStringConvertIANACharSetNameToEncoding(cs as CFString)
            if enc != kCFStringEncodingInvalidId {
                let ns = CFStringConvertEncodingToNSStringEncoding(enc)
                if let s = String(data: data, encoding: String.Encoding(rawValue: ns)) { return s }
            }
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .unicode) { return s }
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: gb)) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    static func parseHeaders(_ raw: String) -> [String: String] {
        guard !raw.isEmpty,
              let d = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in obj { out[k] = Flex.str(v) }
        return out
    }
}
