import AppKit
import CryptoKit
import Foundation
import GoogleTasksCore
import Network

@MainActor
final class OAuthManager: ObservableObject {
    @Published private(set) var isAuthenticated = false

    private let tokenStore: TokenStoring

    var clientID: String {
        LocalEnvironment.value(for: "GOOGLE_TASKS_CLIENT_ID")
    }

    var clientSecret: String {
        LocalEnvironment.value(for: "GOOGLE_TASKS_CLIENT_SECRET")
    }

    init(tokenStore: TokenStoring = KeychainTokenStore()) {
        self.tokenStore = tokenStore
        isAuthenticated = (try? tokenStore.load()) != nil
    }

    func validAccessToken() async throws -> String {
        guard let tokens = try tokenStore.load() else {
            throw GoogleTasksAPIError.missingToken
        }
        if !tokens.isExpired {
            return tokens.accessToken
        }
        if let refreshToken = tokens.refreshToken {
            let refreshed = try await refresh(refreshToken: refreshToken)
            try tokenStore.save(refreshed)
            await MainActor.run { self.isAuthenticated = true }
            return refreshed.accessToken
        }
        throw GoogleTasksAPIError.missingToken
    }

    func signIn() async throws {
        guard !clientID.isEmpty else {
            throw OAuthError.missingClientID
        }
        guard !clientSecret.isEmpty else {
            throw OAuthError.missingClientSecret
        }

        let verifier = PKCE.makeVerifier()
        let challenge = PKCE.challenge(for: verifier)
        let redirectServer = try LocalOAuthRedirectServer()
        let redirectURI = redirectServer.redirectURI

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/tasks"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]

        NSWorkspace.shared.open(components.url!)
        let code = try await redirectServer.waitForCode()

        let tokens = try await exchangeCode(code, verifier: verifier, redirectURI: redirectURI)
        try tokenStore.save(tokens)
        isAuthenticated = true
    }

    func signOut() throws {
        try tokenStore.delete()
        isAuthenticated = false
    }

    private func exchangeCode(_ code: String, verifier: String, redirectURI: String) async throws -> OAuthTokens {
        try await tokenRequest(parameters: [
            "client_id": clientID,
            "client_secret": clientSecret,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI
        ])
    }

    private func refresh(refreshToken: String) async throws -> OAuthTokens {
        var parameters = [
            "client_id": clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]
        if !clientSecret.isEmpty {
            parameters["client_secret"] = clientSecret
        }
        var tokens = try await tokenRequest(parameters: parameters)
        tokens.refreshToken = tokens.refreshToken ?? refreshToken
        return tokens
    }

    private func tokenRequest(parameters: [String: String]) async throws -> OAuthTokens {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = parameters
            .map { "\($0.key)=\($0.value.formURLEncoded)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw OAuthError.tokenExchangeFailed(String(data: data, encoding: .utf8) ?? "")
        }

        let payload = try JSONDecoder().decode(TokenResponse.self, from: data)
        return OAuthTokens(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(payload.expiresIn))
        )
    }
}

enum OAuthError: LocalizedError, Equatable {
    case missingClientID
    case missingClientSecret
    case missingAuthorizationCode
    case cancelled
    case redirectServerUnavailable
    case tokenExchangeFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            "Defina GOOGLE_TASKS_CLIENT_ID antes de fazer login."
        case .missingClientSecret:
            "Defina GOOGLE_TASKS_CLIENT_SECRET antes de fazer login."
        case .missingAuthorizationCode:
            "O Google nao retornou o codigo de autorizacao."
        case .cancelled:
            "Login cancelado."
        case .redirectServerUnavailable:
            "Nao foi possivel iniciar o servidor local de login."
        case let .tokenExchangeFailed(body):
            "Falha ao trocar token: \(body)"
        }
    }
}

private final class LocalOAuthRedirectServer: @unchecked Sendable {
    private static let callbackPorts: [UInt16] = [53682, 53683, 53684, 53685, 53686]
    private let listener: NWListener
    private let port: UInt16
    private var continuation: CheckedContinuation<String, Error>?
    private var didResume = false

    var redirectURI: String {
        "http://localhost:\(port)/oauth2redirect"
    }

    init() throws {
        var createdListener: NWListener?
        var createdPort: UInt16?
        var lastError: Error?

        for candidate in Self.callbackPorts {
            do {
                createdListener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: candidate)!)
                createdPort = candidate
                break
            } catch {
                lastError = error
            }
        }

        guard let createdListener, let createdPort else {
            throw lastError ?? OAuthError.redirectServerUnavailable
        }

        listener = createdListener
        port = createdPort
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: .main)
    }

    deinit {
        listener.cancel()
    }

    func waitForCode() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                self.finish(.failure(error))
                return
            }
            guard
                let data,
                let request = String(data: data, encoding: .utf8),
                let requestLine = request.components(separatedBy: "\r\n").first,
                let path = requestLine.split(separator: " ").dropFirst().first,
                let url = URL(string: "http://localhost\(path)"),
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            else {
                self.respond(connection, message: "Nao foi possivel ler o retorno do Google Tasks.")
                self.finish(.failure(OAuthError.missingAuthorizationCode))
                return
            }

            if let error = components.queryItems?.first(where: { $0.name == "error" })?.value {
                self.respond(connection, message: "Login cancelado ou recusado: \(error)")
                self.finish(.failure(OAuthError.cancelled))
                return
            }

            guard let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
                self.respond(connection, message: "O Google nao retornou codigo de autorizacao.")
                self.finish(.failure(OAuthError.missingAuthorizationCode))
                return
            }

            self.respond(connection, message: "Login concluido. Pode voltar para o Google Tasks macOS.")
            self.finish(.success(code))
        }
    }

    private func respond(_ connection: NWConnection, message: String) {
        let body = "<html><body><h2>\(message)</h2></body></html>"
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func finish(_ result: Result<String, Error>) {
        guard !didResume else { return }
        didResume = true
        listener.cancel()
        switch result {
        case let .success(code):
            continuation?.resume(returning: code)
        case let .failure(error):
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }
}

private struct TokenResponse: Decodable {
    var accessToken: String
    var refreshToken: String?
    var expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

private enum PKCE {
    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    var formURLEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
            .replacingOccurrences(of: "+", with: "%2B") ?? self
    }
}
