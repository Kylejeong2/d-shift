import Foundation

/// Web search and page fetching through the Browserbase Search and Fetch APIs. Requests run on Browserbase's side,
/// so the model can't use these to reach the user's local network.
enum Browserbase {
    private static let baseURL = URL(string: "https://api.browserbase.com/v1/")!

    static func post(_ path: String, body: JSON) async throws -> JSON {
        guard let apiKey = Config.value("BROWSERBASE_API_KEY") else {
            throw ToolError.failed(
                "BROWSERBASE_API_KEY is not set. Add it to ~/.config/dshift/.env and open a new chat tab.")
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "X-BB-API-Key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw ToolError.failed(
                "Browserbase \(path) failed with HTTP \(status): \(String(decoding: data, as: UTF8.self))")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? JSON else {
            throw ToolError.failed("Browserbase \(path) returned an unexpected response")
        }
        return json
    }
}

struct WebSearchTool: Tool {
    let name = "web_search"
    let description = """
        Search the web. Returns up to `num_results` results, each with a title, URL, and author and date when known. \
        Follow up with web_fetch to read a result.
        """
    let inputSchema: JSON = [
        "type": "object",
        "properties": [
            "query": ["type": "string", "description": "The search query."],
            "num_results": ["type": "integer", "minimum": 1, "maximum": 25, "description": "Defaults to 8."],
        ],
        "required": ["query"],
        "additionalProperties": false,
    ]
    let maxCallsPerTurn: Int? = 5

    func requiresApproval(for input: JSON) -> Bool { false }

    func run(_ input: JSON) async throws -> ToolOutput {
        let response = try await Browserbase.post(
            "search", body: ["query": input["query"] as? String ?? "", "numResults": input["num_results"] as? Int ?? 8])
        let results = response["results"] as? [JSON] ?? []
        guard !results.isEmpty else { return ToolOutput(text: "No results.") }
        return ToolOutput(
            text: results.map { result in
                let url = result["url"] as? String ?? ""
                let details = [result["author"] as? String, result["publishedDate"] as? String].compactMap { $0 }
                let title = result["title"] as? String ?? url
                return "\(title)\n  \(url)" + (details.isEmpty ? "" : "\n  \(details.joined(separator: ", "))")
            }.joined(separator: "\n"))
    }
}

struct WebFetchTool: Tool {
    private static let maxCharacters = 40_000

    let name = "web_fetch"
    let description = """
        Fetch a web page by URL and return its readable text (HTML is reduced to text, long pages are truncated). \
        Doesn't run JavaScript, so pages that render client-side may come back mostly empty.
        """
    let inputSchema: JSON = [
        "type": "object",
        "properties": [
            "url": ["type": "string", "description": "An absolute http(s) URL."]
        ],
        "required": ["url"],
        "additionalProperties": false,
    ]
    let maxCallsPerTurn: Int? = 5

    func requiresApproval(for input: JSON) -> Bool { false }

    func run(_ input: JSON) async throws -> ToolOutput {
        let url = input["url"] as? String ?? ""
        guard let scheme = URL(string: url)?.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw ToolError.invalidInput("\"url\" must be an absolute http(s) URL")
        }
        let response = try await Browserbase.post("fetch", body: ["url": url, "allowRedirects": true])
        let status = response["statusCode"] as? Int ?? 0
        let contentType = response["contentType"] as? String ?? ""
        let content = response["content"] as? String ?? ""
        let text = contentType.contains("html") ? Self.readableText(fromHTML: content) : content
        let truncated =
            text.count > Self.maxCharacters ? String(text.prefix(Self.maxCharacters)) + "\n[truncated]" : text
        return ToolOutput(text: "HTTP \(status) \(url)\n\n\(truncated)")
    }

    static func readableText(fromHTML html: String) -> String {
        html
            .replacingOccurrences(
                of: "<(script|style|noscript|svg|head)[^>]*>[\\s\\S]*?</\\1>", with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ", options: .regularExpression)
            .replacingOccurrences(
                of: "<(br|/p|/div|/li|/h[1-6]|/tr)[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s*\\n\\s*", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
