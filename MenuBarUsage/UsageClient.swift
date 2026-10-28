import Foundation

enum UsageClientError: LocalizedError {
    case unauthorized
    case transport
    case badResponse(Int)
    case undecodable

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Cursor did not accept the session."
        case .transport:
            return "The usage service could not be reached."
        case let .badResponse(code):
            return "The usage service returned HTTP \(code)."
        case .undecodable:
            return "The usage response was not readable."
        }
    }
}

struct UsageFetch {
    var summary: UsageSummaryDTO
    var plan: PlanInfoDTO?
    var period: PeriodUsageDTO?
    var sand: SandUsageDTO?
    var sandFailed: Bool
}

final class UsageClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = UsageClient()

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 25
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }

    /// `includePlan` is false when plan info was fetched within the last hour.
    /// The summary request stays first so an auth failure does not fan out.
    /// The optional posts then run together.
    func fetch(cookie: String, includePlan: Bool = true) async throws -> UsageFetch {
        let summaryData = try await send(
            url: URL(string: "https://cursor.com/api/usage-summary")!,
            method: "GET",
            cookie: cookie,
            referer: "https://cursor.com/dashboard/usage"
        )
        let decoder = UsageDecoding.decoder()
        let summary: UsageSummaryDTO
        do {
            summary = try decoder.decode(UsageSummaryDTO.self, from: summaryData)
        } catch {
            throw UsageClientError.undecodable
        }

        async let plan = loadPlan(includePlan, cookie: cookie)
        async let period = sendOptional(
            url: URL(string: "https://cursor.com/api/dashboard/get-current-period-usage")!,
            method: "POST",
            cookie: cookie,
            referer: "https://cursor.com/dashboard/usage",
            as: PeriodUsageDTO.self
        )
        async let sand = sendOptional(
            url: URL(string: "https://cursor.com/api/dashboard/get-sand-usage-status")!,
            method: "POST",
            cookie: cookie,
            referer: "https://cursor.com/bot",
            as: SandUsageDTO.self
        )
        let planValue = await plan
        let periodValue = await period
        let sandValue = await sand

        return UsageFetch(
            summary: summary,
            plan: planValue,
            period: periodValue,
            sand: sandValue,
            sandFailed: sandValue == nil
        )
    }

    private func loadPlan(_ include: Bool, cookie: String) async -> PlanInfoDTO? {
        guard include else { return nil }
        return await sendOptional(
            url: URL(string: "https://cursor.com/api/dashboard/get-plan-info")!,
            method: "POST",
            cookie: cookie,
            referer: "https://cursor.com/dashboard/usage",
            as: PlanInfoDTO.self
        )
    }

    private func sendOptional<T: Decodable>(
        url: URL,
        method: String,
        cookie: String,
        referer: String,
        as type: T.Type
    ) async -> T? {
        do {
            let data = try await send(url: url, method: method, cookie: cookie, referer: referer)
            return try UsageDecoding.decoder().decode(T.self, from: data)
        } catch {
            return nil
        }
    }

    private func send(url: URL, method: String, cookie: String, referer: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("WorkosCursorSessionToken=\(cookie)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("MenuBarUsage/1.0", forHTTPHeaderField: "User-Agent")
        if method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{}".utf8)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageClientError.transport
        }
        guard let http = response as? HTTPURLResponse else { throw UsageClientError.transport }
        switch http.statusCode {
        case 200:
            break
        case 401, 403, 300..<400:
            throw UsageClientError.unauthorized
        default:
            throw UsageClientError.badResponse(http.statusCode)
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = (object["error"] as? String)?.lowercased(),
           ["not_authenticated", "unauthorized", "unauthenticated"].contains(error) {
            throw UsageClientError.unauthorized
        }
        return data
    }
}
