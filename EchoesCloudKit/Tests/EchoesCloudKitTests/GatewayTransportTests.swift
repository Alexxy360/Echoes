import Foundation
import Testing

@testable import EchoesCloudKit

private final class TransportPlan: @unchecked Sendable {
    enum Reply: Sendable {
        case json(Data)
        case redirect
        case stream(Data)
    }
    private let lock = NSLock()
    private var replies: [String: Reply] = [:]
    private var visited: [String: [URL]] = [:]
    func install(_ reply: Reply) -> URL {
        let url = URL(string: "https://native-" + UUID().uuidString.lowercased() + ".example.invalid")!
        lock.withLock {
            replies[url.host!] = reply
            visited[url.host!] = []
        }
        return url
    }
    func take(_ url: URL) -> Reply? {
        lock.withLock {
            let key = url.host!.replacingOccurrences(of: "redirect-target-", with: "")
            visited[key, default: []].append(url)
            if url.host!.hasPrefix("redirect-target-") { return .json(Data("{}".utf8)) }
            return replies[key]
        }
    }
    func finish(_ origin: URL) -> [URL] {
        lock.withLock {
            replies.removeValue(forKey: origin.host!)
            return visited.removeValue(forKey: origin.host!) ?? []
        }
    }
}

/// An in-process URL loading protocol, not an HTTPS endpoint or a real gateway.
private final class GatewayURLProtocol: URLProtocol, @unchecked Sendable {
    static let plan = TransportPlan()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let reply = Self.plan.take(url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        switch reply {
        case .redirect:
            let target = URL(string: "https://redirect-target-" + url.host! + "/stolen")!
            let response = HTTPURLResponse(
                url: url, statusCode: 307, httpVersion: "HTTP/1.1",
                headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
        case .json(let data), .stream(let data):
            let headers: [String: String]
            if case .stream = reply {
                headers = ["Content-Type": "application/json"]
            } else {
                headers = ["Content-Type": "application/json", "Content-Length": String(data.count)]
            }
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@Test func nativeURLSessionRefusesCrossOriginRedirectBeforeSendingCredentials() async throws {
    let origin = GatewayURLProtocol.plan.install(.redirect)
    defer { _ = GatewayURLProtocol.plan.finish(origin) }
    let transport = NativeGatewayTransport(protocolClasses: [GatewayURLProtocol.self])
    let client = try GatewayHTTPClient(
        configuration: GatewayConfiguration(origin: origin), transport: transport)
    await #expect(throws: GatewayFailure.self) {
        try await client.renew(token: GatewaySecret("synthetic-bearer"))
    }
    let visited = GatewayURLProtocol.plan.finish(origin)
    #expect(visited.count == 1)
    #expect(visited.allSatisfy { $0.host == origin.host })
}

@Test func nativeURLSessionBoundsUnannouncedStreamAndAnnouncedLength() async throws {
    for reply in [
        TransportPlan.Reply.stream(Data(repeating: 1, count: 32_769)),
        .json(Data(repeating: 1, count: 32_769)),
    ] {
        let origin = GatewayURLProtocol.plan.install(reply)
        let transport = NativeGatewayTransport(protocolClasses: [GatewayURLProtocol.self])
        let client = try GatewayHTTPClient(
            configuration: GatewayConfiguration(origin: origin), transport: transport)
        await #expect(throws: GatewayFailure.invalidResponse) {
            try await client.renew(token: GatewaySecret("synthetic-bearer"))
        }
        #expect(GatewayURLProtocol.plan.finish(origin).count == 1)
    }
}
