import Foundation

actor AuthService {
    private let apiClient: EeroAPIClientProtocol
    private let credentialStore: CredentialStore

    init(apiClient: EeroAPIClientProtocol, credentialStore: CredentialStore) {
        self.apiClient = apiClient
        self.credentialStore = credentialStore
    }

    func restoreSession() async -> Bool {
        do {
            guard let token = try credentialStore.loadUserToken() else {
                await apiClient.setUserToken(nil)
                return false
            }

            await apiClient.setUserToken(token)
            let response = try await apiClient.refreshSession()
            try credentialStore.saveUserToken(response.userToken)
            return true
        } catch {
            try? credentialStore.clearUserToken()
            await apiClient.setUserToken(nil)
            return false
        }
    }

    func login(login: String) async throws {
        let response = try await apiClient.login(login: login)
        try credentialStore.saveUserToken(response.userToken)
    }

    func verify(code: String) async throws -> VerifyResponse {
        let response = try await apiClient.verify(code: code)
        if let token = await apiClient.currentUserToken() {
            try credentialStore.saveUserToken(token)
        }
        return response
    }

    func logout() async {
        try? credentialStore.clearUserToken()
        await apiClient.setUserToken(nil)
    }
}
