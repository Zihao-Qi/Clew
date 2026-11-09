import ClewCore
import Foundation

/// The app's only network use (SPEC §8): one GET of a link the user just pasted, to
/// read its title. No cookies, no cache, no redirects off http(s), text/html only,
/// at most 3 MB (YouTube's og:title sits ~800 KB in), stopping early at `</head>`.
enum TitleFetcher {
    static let maxBytes = 3_000_000

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        config.httpAdditionalHeaders = ["User-Agent": "Clew/0.1 (macOS; title fetch)", "Accept": "text/html"]
        return URLSession(configuration: config)
    }()

    static func title(for url: URL) async -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  http.mimeType?.lowercased() == "text/html",
                  let finalScheme = http.url?.scheme?.lowercased(), finalScheme == "http" || finalScheme == "https"
            else { return nil }
            var data = Data()
            data.reserveCapacity(256_000)
            let headEnd = Data("</head>".utf8)
            for try await byte in bytes {
                data.append(byte)
                if data.count >= maxBytes { break }
                if data.count % 65_536 == 0, data.range(of: headEnd) != nil { break }
            }
            return PageTitle.extract(fromHTML: String(decoding: data, as: UTF8.self))
        } catch {
            return nil
        }
    }
}
