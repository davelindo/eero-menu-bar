import Foundation

struct LoginResponse: Sendable {
    var userToken: String
}

struct VerifyResponse: Sendable {
    var accountName: String?
    var accountID: String?
}

struct RefreshResponse: Sendable {
    var userToken: String
}

struct UpdateConfig: Sendable {
    var networkIDs: Set<String> = []
}

enum EeroRouteCatalog {
    static let getResourceKeys: Set<String> = [
        "account",
        "networks",
        "ac_compat",
        "channel_utilization",
        "device_blacklist",
        "devices",
        "diagnostics",
        "eeros",
        "forwards",
        "guestnetwork",
        "insights",
        "ouicheck",
        "profiles",
        "proxied_nodes",
        "reservations",
        "routing",
        "speedtest",
        "support",
        "thread",
        "updates"
    ]

    static let postResourceKeys: Set<String> = [
        "burst_reporters",
        "reboot",
        "reboot_eero",
        "run_speedtest"
    ]
}

enum EeroAPIError: Error, LocalizedError {
    case unauthenticated
    case invalidResponse
    case invalidPayload
    case server(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .unauthenticated:
            return "Not authenticated with eero."
        case .invalidResponse:
            return "Invalid response from eero API."
        case .invalidPayload:
            return "Unexpected eero API payload."
        case .server(let code, let message):
            return "Eero API error (\(code)): \(message)"
        }
    }
}

protocol EeroAPIClientProtocol: Sendable {
    func setUserToken(_ token: String?) async
    func currentUserToken() async -> String?
    func login(login: String) async throws -> LoginResponse
    func verify(code: String) async throws -> VerifyResponse
    func refreshSession() async throws -> RefreshResponse
    func fetchAccount(config: UpdateConfig) async throws -> EeroAccountSnapshot
    func perform(_ action: EeroAction) async throws
}

actor EeroAPIClient: EeroAPIClientProtocol {
    private let baseURL = URL(string: "https://api-user.e2ro.com")!
    private let session: URLSession
    private var userToken: String?

    init(session: URLSession = .shared) {
        self.session = session
    }

    func setUserToken(_ token: String?) async {
        userToken = token
    }

    func currentUserToken() async -> String? {
        userToken
    }

    func login(login: String) async throws -> LoginResponse {
        let response = try await call(
            method: .post,
            pathOrURL: "/2.2/login",
            json: ["login": login],
            requiresAuth: false,
            retryOnAuthFailure: false
        )

        guard let payload = response as? [String: Any],
              let token = payload["user_token"] as? String else {
            throw EeroAPIError.invalidPayload
        }

        userToken = token
        return LoginResponse(userToken: token)
    }

    func verify(code: String) async throws -> VerifyResponse {
        let response = try await call(
            method: .post,
            pathOrURL: "/2.2/login/verify",
            json: ["code": code],
            requiresAuth: true,
            retryOnAuthFailure: false
        )

        guard let payload = response as? [String: Any] else {
            throw EeroAPIError.invalidPayload
        }

        return VerifyResponse(
            accountName: payload["name"] as? String,
            accountID: payload["log_id"] as? String
        )
    }

    func refreshSession() async throws -> RefreshResponse {
        let response = try await call(
            method: .post,
            pathOrURL: "/2.2/login/refresh",
            json: nil,
            requiresAuth: true,
            retryOnAuthFailure: false
        )

        guard let payload = response as? [String: Any],
              let token = payload["user_token"] as? String else {
            throw EeroAPIError.invalidPayload
        }

        userToken = token
        return RefreshResponse(userToken: token)
    }

    func fetchAccount(config: UpdateConfig = UpdateConfig()) async throws -> EeroAccountSnapshot {
        guard let account = try await call(method: .get, pathOrURL: "/2.2/account", json: nil, requiresAuth: true) as? [String: Any] else {
            throw EeroAPIError.invalidPayload
        }

        let networkRefs = DictionaryValue.dictArray(in: account, path: ["networks", "data"])
        var networks: [EeroNetwork] = []

        for ref in networkRefs {
            guard let networkURL = DictionaryValue.string(in: ref, path: ["url"]) else {
                continue
            }

            let networkID = DictionaryValue.id(fromURL: networkURL)
            if !config.networkIDs.isEmpty, !config.networkIDs.contains(networkID) {
                continue
            }

            guard var networkData = try await call(method: .get, pathOrURL: networkURL, json: nil, requiresAuth: true) as? [String: Any] else {
                continue
            }

            let resources = DictionaryValue.stringMap(in: networkData, path: ["resources"])

            if let thread = await fetchResourceData(
                resources: resources,
                resourceKeys: ["thread"],
                fallbackPath: "/2.2/networks/\(networkID)/thread"
            ) as? [String: Any] {
                networkData["thread"] = thread
            }

            if let guestNetwork = await fetchResourceData(
                resources: resources,
                resourceKeys: ["guestnetwork", "guest_network"],
                fallbackPath: "/2.2/networks/\(networkID)/guestnetwork"
            ) as? [String: Any] {
                networkData["guest_network"] = guestNetwork
            }

            if let devices = await fetchResourceData(
                resources: resources,
                resourceKeys: ["devices", "clients"],
                fallbackPath: "/2.2/networks/\(networkID)/devices"
            ) as? [[String: Any]] {
                networkData["devices"] = ["count": devices.count, "data": devices]
            }

            if let profiles = await fetchResourceData(
                resources: resources,
                resourceKeys: ["profiles"],
                fallbackPath: "/2.2/networks/\(networkID)/profiles"
            ) as? [[String: Any]] {
                networkData["profiles"] = ["count": profiles.count, "data": profiles]
            }

            if let eeros = await fetchResourceData(
                resources: resources,
                resourceKeys: ["eeros"],
                fallbackPath: "/2.2/networks/\(networkID)/eeros"
            ) as? [[String: Any]] {
                let enrichedEeros = await fetchExpandedEeros(eeros)
                networkData["eeros"] = ["count": enrichedEeros.count, "data": enrichedEeros]
            }

            if let acCompat = await fetchResourceData(
                resources: resources,
                resourceKeys: ["ac_compat"],
                fallbackPath: "/2.2/networks/\(networkID)/ac_compat"
            ) as? [String: Any] {
                networkData["ac_compat"] = acCompat
            }

            if let blacklist = await fetchResourceData(
                resources: resources,
                resourceKeys: ["blacklist", "device_blacklist"],
                fallbackPath: "/2.2/networks/\(networkID)/blacklist"
            ) as? [[String: Any]] {
                networkData["device_blacklist"] = ["count": blacklist.count, "data": blacklist]
            }

            if let diagnostics = await fetchResourceData(
                resources: resources,
                resourceKeys: ["diagnostics"],
                fallbackPath: "/2.2/networks/\(networkID)/diagnostics"
            ) as? [String: Any] {
                networkData["diagnostics"] = diagnostics
            }

            if let forwards = await fetchResourceData(
                resources: resources,
                resourceKeys: ["forwards"],
                fallbackPath: "/2.2/networks/\(networkID)/forwards"
            ) as? [[String: Any]] {
                networkData["forwards"] = ["count": forwards.count, "data": forwards]
            }

            if let reservations = await fetchResourceData(
                resources: resources,
                resourceKeys: ["reservations"],
                fallbackPath: "/2.2/networks/\(networkID)/reservations"
            ) as? [[String: Any]] {
                networkData["reservations"] = ["count": reservations.count, "data": reservations]
            }

            if let routing = await fetchResourceData(
                resources: resources,
                resourceKeys: ["routing"],
                fallbackPath: "/2.2/networks/\(networkID)/routing"
            ) as? [String: Any] {
                networkData["routing"] = routing
            }

            if let speedTest = await fetchResourceData(
                resources: resources,
                resourceKeys: ["speedtest"],
                fallbackPath: "/2.2/networks/\(networkID)/speedtest"
            ) {
                networkData["speedtest"] = speedTest
            }

            if let updates = await fetchResourceData(
                resources: resources,
                resourceKeys: ["updates"],
                fallbackPath: "/2.2/networks/\(networkID)/updates"
            ) as? [String: Any] {
                networkData["updates"] = updates
            }

            if let support = await fetchResourceData(
                resources: resources,
                resourceKeys: ["support"],
                fallbackPath: "/2.2/networks/\(networkID)/support"
            ) as? [String: Any] {
                networkData["support"] = support
            }

            if let insights = await fetchResourceData(
                resources: resources,
                resourceKeys: ["insights"],
                fallbackPath: "/2.2/networks/\(networkID)/insights"
            ) {
                networkData["insights_response"] = insights
            }

            if let ouicheck = await fetchResourceData(
                resources: resources,
                resourceKeys: ["ouicheck"],
                fallbackPath: "/2.2/networks/\(networkID)/ouicheck"
            ) {
                networkData["ouicheck_response"] = ouicheck
            }

            let timezoneIdentifier = DictionaryValue.string(in: networkData, path: ["timezone", "value"]) ?? TimeZone.current.identifier

            if let activity = await fetchActivitySnapshot(networkURL: networkURL, timezoneIdentifier: timezoneIdentifier) {
                networkData["activity"] = activity
            }

            if let channelUtilization = await fetchChannelUtilizationSnapshot(networkURL: networkURL, timezoneIdentifier: timezoneIdentifier) {
                networkData["channel_utilization"] = channelUtilization
            }

            if let proxiedNodes = await fetchResourceData(
                resources: resources,
                resourceKeys: ["proxied_nodes"],
                fallbackPath: "/2.2/networks/\(networkID)/proxied_nodes"
            ) as? [String: Any] {
                networkData["proxied_nodes"] = proxiedNodes
            }

            networks.append(Self.parseNetwork(networkData))
        }

        return EeroAccountSnapshot(fetchedAt: Date(), networks: networks)
    }

    private func fetchResourceData(
        resources: [String: String],
        resourceKeys: [String],
        fallbackPath: String
    ) async -> Any? {
        let pathOrURL = resourceKeys.compactMap { resources[$0] }.first ?? fallbackPath
        return try? await call(method: .get, pathOrURL: pathOrURL, json: nil, requiresAuth: true)
    }

    private func fetchExpandedEeros(_ eeros: [[String: Any]]) async -> [[String: Any]] {
        var expanded: [[String: Any]] = []
        expanded.reserveCapacity(eeros.count)

        for eero in eeros {
            guard let url = DictionaryValue.string(in: eero, path: ["url"]),
                  let detail = try? await call(method: .get, pathOrURL: url, json: nil, requiresAuth: true) as? [String: Any] else {
                expanded.append(eero)
                continue
            }

            var enriched = Self.deepMergeDictionary(base: eero, incoming: detail)
            let resources = DictionaryValue.stringMap(in: detail, path: ["resources"])
            if let connectionsPath = resources["connections"],
               let connections = try? await call(method: .get, pathOrURL: connectionsPath, json: nil, requiresAuth: true) {
                enriched["connections"] = connections
            }

            expanded.append(enriched)
        }

        return expanded
    }

    private static func deepMergeDictionary(base: [String: Any], incoming: [String: Any]) -> [String: Any] {
        var merged = base
        for (key, incomingValue) in incoming {
            if let incomingDict = incomingValue as? [String: Any],
               let existingDict = merged[key] as? [String: Any] {
                merged[key] = deepMergeDictionary(base: existingDict, incoming: incomingDict)
            } else {
                merged[key] = incomingValue
            }
        }
        return merged
    }

    private func fetchActivitySnapshot(networkURL: String, timezoneIdentifier: String) async -> [String: Any]? {
        let periods = ["day", "week", "month"]
        var networkUsage: [String: Any] = [:]
        var eeroUsage: [String: Any] = [:]
        var deviceUsage: [String: Any] = [:]

        for period in periods {
            if let values = await fetchDataUsageSeries(path: "\(networkURL)/data_usage", timezoneIdentifier: timezoneIdentifier, period: period) {
                networkUsage["data_usage_\(period)"] = values
            }
            if let values = await fetchDataUsageSeries(path: "\(networkURL)/data_usage/eeros", timezoneIdentifier: timezoneIdentifier, period: period) {
                eeroUsage["data_usage_\(period)"] = values
            }
        }

        // Pull per-device usage rollups when available; keep best-effort so the app remains usable for non-premium networks.
        if let values = await fetchDeviceUsageSnapshot(networkURL: networkURL, timezoneIdentifier: timezoneIdentifier, period: "day") {
            deviceUsage["data_usage_day"] = values
        }
        if let values = await fetchDeviceUsageSnapshot(networkURL: networkURL, timezoneIdentifier: timezoneIdentifier, period: "week") {
            deviceUsage["data_usage_week"] = values
        }
        if let values = await fetchDeviceUsageSnapshot(networkURL: networkURL, timezoneIdentifier: timezoneIdentifier, period: "month") {
            deviceUsage["data_usage_month"] = values
        }
        if let timelines = await fetchDeviceUsageTimelines(
            networkURL: networkURL,
            timezoneIdentifier: timezoneIdentifier,
            from: deviceUsage,
            limit: 5
        ), !timelines.isEmpty {
            deviceUsage["device_timelines"] = timelines
        }

        var activity: [String: Any] = [:]
        if !networkUsage.isEmpty {
            activity["network"] = networkUsage
        }
        if !eeroUsage.isEmpty {
            activity["eeros"] = eeroUsage
        }
        if !deviceUsage.isEmpty {
            activity["devices"] = deviceUsage
        }

        return activity.isEmpty ? nil : activity
    }

    private func fetchDeviceUsageTimelines(
        networkURL: String,
        timezoneIdentifier: String,
        from deviceUsage: [String: Any],
        limit: Int
    ) async -> [[String: Any]]? {
        let sourceRows = topDeviceUsageRows(from: deviceUsage, limit: limit)
        guard !sourceRows.isEmpty else {
            return nil
        }

        guard let queryWindow = activityQueryWindow(timezoneIdentifier: timezoneIdentifier, period: "day") else {
            return nil
        }

        var timelines: [[String: Any]] = []
        timelines.reserveCapacity(sourceRows.count)

        for row in sourceRows {
            guard let macAddress = row.macAddress,
                  let encodedMAC = macAddress.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
                continue
            }

            let queryItems = [
                URLQueryItem(name: "start", value: queryWindow.start),
                URLQueryItem(name: "end", value: queryWindow.end),
                URLQueryItem(name: "cadence", value: "hourly"),
                URLQueryItem(name: "timezone", value: timezoneIdentifier)
            ]

            guard let queryPath = withQueryItems(pathOrURL: "\(networkURL)/data_usage/devices/\(encodedMAC)", queryItems: queryItems),
                  let response = try? await call(method: .get, pathOrURL: queryPath, json: nil, requiresAuth: true) else {
                continue
            }

            var payload: [String: Any] = [
                "resource_key": row.resourceKey,
                "mac": macAddress
            ]
            if let displayName = row.displayName {
                payload["display_name"] = displayName
            }
            payload["payload"] = response
            timelines.append(payload)
        }

        return timelines.isEmpty ? nil : timelines
    }

    private func topDeviceUsageRows(from deviceUsage: [String: Any], limit: Int) -> [(resourceKey: String, macAddress: String?, displayName: String?)] {
        let candidateRows = [
            Self.usageRows(in: deviceUsage, path: ["data_usage_month"]),
            Self.usageRows(in: deviceUsage, path: ["data_usage_week"]),
            Self.usageRows(in: deviceUsage, path: ["data_usage_day"])
        ]
        .flatMap { $0 }

        guard !candidateRows.isEmpty else {
            return []
        }

        var scoreByResource: [String: Int] = [:]
        var metadataByResource: [String: (macAddress: String?, displayName: String?)] = [:]

        for row in candidateRows {
            guard let resourceKey = Self.resourceKeyForUsageRow(row) else {
                continue
            }

            let usageScore = max(0, Self.integerValue(DictionaryValue.value(in: row, path: ["download"])) ?? 0)
                + max(0, Self.integerValue(DictionaryValue.value(in: row, path: ["upload"])) ?? 0)
            scoreByResource[resourceKey, default: 0] += usageScore

            let macAddress = DictionaryValue.string(in: row, path: ["mac"]) ?? Self.macAddressFromResourceKey(resourceKey)
            let displayName = DictionaryValue.string(in: row, path: ["display_name"])
                ?? DictionaryValue.string(in: row, path: ["nickname"])
                ?? DictionaryValue.string(in: row, path: ["hostname"])

            if metadataByResource[resourceKey] == nil {
                metadataByResource[resourceKey] = (macAddress: macAddress, displayName: displayName)
            } else {
                let existing = metadataByResource[resourceKey]
                metadataByResource[resourceKey] = (
                    macAddress: existing?.macAddress ?? macAddress,
                    displayName: existing?.displayName ?? displayName
                )
            }
        }

        return scoreByResource
            .sorted { lhs, rhs in
                if lhs.value != rhs.value {
                    return lhs.value > rhs.value
                }
                return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
            }
            .prefix(max(1, limit))
            .map { entry in
                let metadata = metadataByResource[entry.key]
                return (
                    resourceKey: entry.key,
                    macAddress: metadata?.macAddress,
                    displayName: metadata?.displayName
                )
            }
    }

    private static func macAddressFromResourceKey(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains(":") || trimmed.contains("-") {
            let normalized = trimmed.replacingOccurrences(of: "-", with: ":")
            let components = normalized.split(separator: ":")
            if components.count == 6, components.allSatisfy({ $0.count == 2 }) {
                return components.joined(separator: ":").uppercased()
            }
        }

        let alphanumerics = String(trimmed.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        guard alphanumerics.count == 12 else {
            return nil
        }

        var octets: [String] = []
        octets.reserveCapacity(6)
        var index = alphanumerics.startIndex
        for _ in 0..<6 {
            let next = alphanumerics.index(index, offsetBy: 2)
            octets.append(String(alphanumerics[index..<next]).uppercased())
            index = next
        }
        return octets.joined(separator: ":")
    }

    private func fetchDeviceUsageSnapshot(networkURL: String, timezoneIdentifier: String, period: String) async -> Any? {
        guard let queryWindow = activityQueryWindow(timezoneIdentifier: timezoneIdentifier, period: period) else {
            return nil
        }

        let queryItems = [
            URLQueryItem(name: "start", value: queryWindow.start),
            URLQueryItem(name: "end", value: queryWindow.end),
            URLQueryItem(name: "cadence", value: queryWindow.cadence),
            URLQueryItem(name: "timezone", value: timezoneIdentifier)
        ]

        guard let queryPath = withQueryItems(pathOrURL: "\(networkURL)/data_usage/devices", queryItems: queryItems),
              let response = try? await call(method: .get, pathOrURL: queryPath, json: nil, requiresAuth: true) else {
            return nil
        }

        if let dict = response as? [String: Any] {
            return dict
        }
        if let rows = response as? [[String: Any]] {
            return ["values": rows]
        }
        return nil
    }

    private func fetchChannelUtilizationSnapshot(networkURL: String, timezoneIdentifier: String) async -> Any? {
        // Keep this to a short window so it stays fast and doesn't bloat UI.
        let now = Date()
        let start = now.addingTimeInterval(-6 * 3600)
        let end = now

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let queryItems = [
            URLQueryItem(name: "start", value: formatter.string(from: start)),
            URLQueryItem(name: "end", value: formatter.string(from: end)),
            URLQueryItem(name: "granularity", value: "fifteen_minutes"),
            URLQueryItem(name: "gap_data_placeholder", value: "true"),
            URLQueryItem(name: "timezone", value: timezoneIdentifier)
        ]

        guard let queryPath = withQueryItems(pathOrURL: "\(networkURL)/channel_utilization", queryItems: queryItems),
              let response = try? await call(method: .get, pathOrURL: queryPath, json: nil, requiresAuth: true) else {
            return nil
        }

        return response
    }

    private func fetchDataUsageSeries(path: String, timezoneIdentifier: String, period: String) async -> [[String: Any]]? {
        guard let queryWindow = activityQueryWindow(timezoneIdentifier: timezoneIdentifier, period: period) else {
            return nil
        }

        let queryItems = [
            URLQueryItem(name: "start", value: queryWindow.start),
            URLQueryItem(name: "end", value: queryWindow.end),
            URLQueryItem(name: "cadence", value: queryWindow.cadence),
            URLQueryItem(name: "timezone", value: timezoneIdentifier)
        ]

        guard let queryPath = withQueryItems(pathOrURL: path, queryItems: queryItems),
              let response = try? await call(method: .get, pathOrURL: queryPath, json: nil, requiresAuth: true) else {
            return nil
        }

        if let rows = response as? [[String: Any]] {
            return rows
        }
        if let dict = response as? [String: Any] {
            if let values = dict["values"] as? [[String: Any]] {
                return values
            }
            if let series = dict["series"] as? [[String: Any]] {
                return series
            }
        }
        return nil
    }

    private func withQueryItems(pathOrURL: String, queryItems: [URLQueryItem]) -> String? {
        guard let resolved = try? resolveURL(pathOrURL),
              var components = URLComponents(url: resolved, resolvingAgainstBaseURL: true) else {
            return nil
        }

        var existing = components.queryItems ?? []
        existing.append(contentsOf: queryItems)
        components.queryItems = existing
        return components.url?.absoluteString
    }

    private func activityQueryWindow(timezoneIdentifier: String, period: String) -> (start: String, end: String, cadence: String)? {
        let timezone = TimeZone(identifier: timezoneIdentifier) ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone

        let now = Date()

        let startDate: Date
        let endDate: Date
        let cadence: String

        switch period {
        case "day":
            let start = calendar.startOfDay(for: now)
            guard let end = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: start) else {
                return nil
            }
            startDate = start
            endDate = end
            cadence = "hourly"
        case "week":
            let weekday = calendar.component(.weekday, from: now)
            let daysFromSunday = weekday - 1
            let startOfToday = calendar.startOfDay(for: now)
            guard let start = calendar.date(byAdding: .day, value: -daysFromSunday, to: startOfToday),
                  let end = calendar.date(byAdding: DateComponents(day: 7, second: -1), to: start) else {
                return nil
            }
            startDate = start
            endDate = end
            cadence = "daily"
        case "month":
            guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)),
                  let end = calendar.date(byAdding: DateComponents(month: 1, second: -1), to: monthStart) else {
                return nil
            }
            startDate = monthStart
            endDate = end
            cadence = "daily"
        default:
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return (
            start: formatter.string(from: startDate),
            end: formatter.string(from: endDate),
            cadence: cadence
        )
    }

    func perform(_ action: EeroAction) async throws {
        let body = action.payload.isEmpty ? nil : action.payload.mapValues(\.anyValue)
        _ = try await call(
            method: action.method,
            pathOrURL: action.endpoint,
            json: body,
            requiresAuth: true
        )
    }

    private func call(
        method: HTTPMethod,
        pathOrURL: String,
        json: [String: Any]?,
        requiresAuth: Bool,
        retryOnAuthFailure: Bool = true
    ) async throws -> Any {
        let url = try resolveURL(pathOrURL)
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.httpMethod = method.rawValue

        if requiresAuth {
            guard let token = userToken, !token.isEmpty else {
                throw EeroAPIError.unauthenticated
            }
            request.addValue("s=\(token)", forHTTPHeaderField: "Cookie")
        }

        if let json {
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json, options: [])
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw EeroAPIError.invalidResponse
        }

        if (200..<300).contains(http.statusCode) {
            return try decodeDataEnvelope(data)
        }

        let message = (try? decodeErrorMessage(data)) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)

        if http.statusCode == 401,
           requiresAuth,
           retryOnAuthFailure,
           pathOrURL != "/2.2/login/refresh" {
            _ = try await refreshSession()
            return try await call(
                method: method,
                pathOrURL: pathOrURL,
                json: json,
                requiresAuth: requiresAuth,
                retryOnAuthFailure: false
            )
        }

        throw EeroAPIError.server(code: http.statusCode, message: message)
    }

    private func resolveURL(_ pathOrURL: String) throws -> URL {
        if let absolute = URL(string: pathOrURL), absolute.scheme != nil {
            return absolute
        }
        guard let relative = URL(string: pathOrURL, relativeTo: baseURL) else {
            throw EeroAPIError.invalidResponse
        }
        return relative
    }

    private func decodeDataEnvelope(_ data: Data) throws -> Any {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        if let dict = object as? [String: Any], let payload = dict["data"] {
            return payload
        }
        return object
    }

    private func decodeErrorMessage(_ data: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        if let dict = object as? [String: Any],
           let meta = dict["meta"] as? [String: Any] {
            let code = meta["code"] as? Int
            let error = meta["error"] as? String
            if let code, let error {
                return "\(error) (\(code))"
            }
            if let error {
                return error
            }
        }
        if let dict = object as? [String: Any],
           let message = dict["message"] as? String {
            return message
        }
        return "Unknown API error"
    }

    private static func parseNetwork(_ data: [String: Any]) -> EeroNetwork {
        let url = DictionaryValue.string(in: data, path: ["url"]) ?? ""
        let id = stableIdentifier(
            primary: DictionaryValue.id(fromURL: url),
            fallbacks: [url, DictionaryValue.string(in: data, path: ["name"]), DictionaryValue.string(in: data, path: ["nickname_label"])],
            prefix: "network"
        )
        let name = DictionaryValue.string(in: data, path: ["name"]) ?? "Network"
        let nickname = DictionaryValue.string(in: data, path: ["nickname_label"])
        let status = DictionaryValue.string(in: data, path: ["status"])
        let premiumCapable = DictionaryValue.bool(in: data, path: ["capabilities", "premium", "capable"]) ?? false
        let premiumStatus = DictionaryValue.string(in: data, path: ["premium_status"]) ?? ""
        let premiumEnabled = premiumCapable && ["active", "trialing"].contains(premiumStatus)
        let resources = DictionaryValue.stringMap(in: data, path: ["resources"])
        let guestNetworkData = DictionaryValue.dict(in: data, path: ["guest_network"]) ?? [:]

        let adBlockProfiles = Set((DictionaryValue.value(in: data, path: ["premium_dns", "ad_block_settings", "profiles"]) as? [String]) ?? [])

        var clients = DictionaryValue.dictArray(in: data, path: ["devices", "data"]).map(Self.parseClient)
        let profiles = DictionaryValue.dictArray(in: data, path: ["profiles", "data"]).map { parseProfile($0, adBlockProfiles: adBlockProfiles) }
        var devices = DictionaryValue.dictArray(in: data, path: ["eeros", "data"]).map(Self.parseDevice)

        let usageDayByDeviceID = usageByResourceID(
            in: data,
            candidatePaths: [
                ["activity", "eeros", "data_usage_day"],
                ["activity", "eeros", "data_usage_day", "values"]
            ]
        )
        let usageWeekByDeviceID = usageByResourceID(
            in: data,
            candidatePaths: [
                ["activity", "eeros", "data_usage_week"],
                ["activity", "eeros", "data_usage_week", "values"]
            ]
        )
        let usageMonthByDeviceID = usageByResourceID(
            in: data,
            candidatePaths: [
                ["activity", "eeros", "data_usage_month"],
                ["activity", "eeros", "data_usage_month", "values"]
            ]
        )

        let usageDayByClientID = usageByResourceID(
            in: data,
            candidatePaths: [
                ["activity", "devices", "data_usage_day"],
                ["activity", "devices", "data_usage_day", "values"]
            ]
        )
        let usageWeekByClientID = usageByResourceID(
            in: data,
            candidatePaths: [
                ["activity", "devices", "data_usage_week"],
                ["activity", "devices", "data_usage_week", "values"]
            ]
        )
        let usageMonthByClientID = usageByResourceID(
            in: data,
            candidatePaths: [
                ["activity", "devices", "data_usage_month"],
                ["activity", "devices", "data_usage_month", "values"]
            ]
        )

        let normalizedUsageDayByClientID = normalizeUsageLookup(usageDayByClientID)
        let normalizedUsageWeekByClientID = normalizeUsageLookup(usageWeekByClientID)
        let normalizedUsageMonthByClientID = normalizeUsageLookup(usageMonthByClientID)

        clients = clients.map { client in
            var updated = client
            if let usageDay = usageValue(for: client, direct: usageDayByClientID, normalized: normalizedUsageDayByClientID) {
                updated.usageDayDownload = usageDay.download
                updated.usageDayUpload = usageDay.upload
            }
            if let usageWeek = usageValue(for: client, direct: usageWeekByClientID, normalized: normalizedUsageWeekByClientID) {
                updated.usageWeekDownload = usageWeek.download
                updated.usageWeekUpload = usageWeek.upload
            }
            if let usageMonth = usageValue(for: client, direct: usageMonthByClientID, normalized: normalizedUsageMonthByClientID) {
                updated.usageMonthDownload = usageMonth.download
                updated.usageMonthUpload = usageMonth.upload
            }
            return updated
        }

        let connectedBySourceID = Dictionary(grouping: clients.compactMap { client -> (String, String)? in
            guard client.connected,
                  let sourceURL = client.sourceURL,
                  !sourceURL.isEmpty else {
                return nil
            }
            let sourceID = DictionaryValue.id(fromURL: sourceURL)
            guard !sourceID.isEmpty else {
                return nil
            }
            return (sourceID, client.name)
        }, by: \.0).mapValues { rows in
            rows.map(\.1).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }

        let clientNameByResourceID: [String: String] = Dictionary(uniqueKeysWithValues: clients.compactMap { client in
            let candidates = [
                client.id,
                trimStablePrefix(client.id),
                client.sourceURL.map { DictionaryValue.id(fromURL: $0) },
                client.mac
            ]
            for candidate in candidates {
                let normalized = normalizeKey(candidate)
                if !normalized.isEmpty {
                    return (normalized, client.name)
                }
            }
            return nil
        })

        let connectedBySourceLocation = Dictionary(grouping: clients.compactMap { client -> (String, String)? in
            guard client.connected,
                  let sourceLocation = client.sourceLocation?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !sourceLocation.isEmpty else {
                return nil
            }
            return (sourceLocation.lowercased(), client.name)
        }, by: \.0).mapValues { rows in
            rows.map(\.1).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }

        devices = devices.map { device in
            var updated = device

            var inferredNames: Set<String> = []

            let sourceIDLookupKeys: [String?] = [device.id, trimStablePrefix(device.id), device.macAddress]
            for key in sourceIDLookupKeys {
                guard let key else { continue }
                if let names = connectedBySourceID[key], !names.isEmpty {
                    inferredNames.formUnion(names)
                }
            }

            if inferredNames.isEmpty {
                let locationKey = device.name.lowercased()
                if let names = connectedBySourceLocation[locationKey], !names.isEmpty {
                    inferredNames.formUnion(names)
                }
            }

            if let wirelessAttachments = updated.wirelessAttachments {
                for attachment in wirelessAttachments {
                    let candidates = [
                        attachment.url.map { DictionaryValue.id(fromURL: $0) },
                        attachment.displayName
                    ]
                    for candidate in candidates {
                        let normalized = normalizeKey(candidate)
                        guard !normalized.isEmpty else { continue }
                        if let resolvedName = clientNameByResourceID[normalized] {
                            inferredNames.insert(resolvedName)
                        }
                    }
                }
            }

            for status in updated.ethernetStatuses {
                let candidates = [status.neighborURL.map { DictionaryValue.id(fromURL: $0) }, status.neighborName]
                for candidate in candidates {
                    let normalized = normalizeKey(candidate)
                    guard !normalized.isEmpty else { continue }
                    if let resolvedName = clientNameByResourceID[normalized] {
                        inferredNames.insert(resolvedName)
                    }
                }
            }

            if !inferredNames.isEmpty {
                let sorted = inferredNames.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                updated.connectedClientNames = sorted
                if updated.connectedClientCount == nil {
                    updated.connectedClientCount = sorted.count
                }
            }

            let usageLookupKeys: [String?] = [device.id, trimStablePrefix(device.id), device.macAddress]
            if let usageDay = firstUsageValue(in: usageDayByDeviceID, keys: usageLookupKeys) {
                updated.usageDayDownload = usageDay.download
                updated.usageDayUpload = usageDay.upload
            }
            if let usageWeek = firstUsageValue(in: usageWeekByDeviceID, keys: usageLookupKeys) {
                updated.usageWeekDownload = usageWeek.download
                updated.usageWeekUpload = usageWeek.upload
            }
            if let usageMonth = firstUsageValue(in: usageMonthByDeviceID, keys: usageLookupKeys) {
                updated.usageMonthDownload = usageMonth.download
                updated.usageMonthUpload = usageMonth.upload
            }

            return updated
        }

        let connectedClientsCount = clients.filter(\.connected).count
        let connectedGuestClientsCount = clients.filter { $0.connected && $0.isGuest }.count

        let blacklistedDevices = DictionaryValue.dictArray(in: data, path: ["device_blacklist", "data"])
        let blacklistedNames = blacklistedDevices.compactMap { entry in
            DictionaryValue.string(in: entry, path: ["nickname"])
                ?? DictionaryValue.string(in: entry, path: ["hostname"])
                ?? DictionaryValue.string(in: entry, path: ["mac"])
        }

        let routingData = DictionaryValue.dict(in: data, path: ["routing"]) ?? [:]
        let routingReservations = DictionaryValue.dictArray(in: routingData, path: ["reservations", "data"])
        let routingForwards = DictionaryValue.dictArray(in: routingData, path: ["forwards", "data"])
        let routingPinholes = DictionaryValue.dictArray(in: routingData, path: ["pinholes", "data"])
        let standaloneReservations = DictionaryValue.dictArray(in: data, path: ["reservations", "data"])
        let standaloneForwards = DictionaryValue.dictArray(in: data, path: ["forwards", "data"])
        let reservationData = routingReservations.isEmpty ? standaloneReservations : routingReservations
        let forwardData = routingForwards.isEmpty ? standaloneForwards : routingForwards

        let speedTestRecord = parseSpeedTestRecord(data["speedtest"])
        let threadDetails = parseThreadDetails(data)

        let historicalInsightsCapable = DictionaryValue.bool(in: data, path: ["capabilities", "historical_insights", "capable"]) ?? false
        let perDeviceInsightsCapable = DictionaryValue.bool(in: data, path: ["capabilities", "per_device_insights", "capable"]) ?? false
        let insightsAvailable = historicalInsightsCapable || perDeviceInsightsCapable || data["insights_response"] != nil || data["ouicheck_response"] != nil

        let burstSummary = parseBurstReporterSummary(data)
        let gatewayDevice = devices.first(where: \.isGateway)
        let gatewayIP = DictionaryValue.string(in: data, path: ["gateway_ip"]) ?? gatewayDevice?.ipAddress
        let meshQuality = average(devices.compactMap(\.meshQualityBars).map(Double.init))
        let wiredBackhaulCount = devices.filter { $0.wiredBackhaul == true }.count
        let wirelessBackhaulCount = devices.filter { $0.wiredBackhaul == false }.count
        let meshSummary: NetworkMeshSummary? = devices.isEmpty
            ? nil
            : NetworkMeshSummary(
                eeroCount: devices.count,
                onlineEeroCount: devices.filter { deviceStatusIsOnline($0.status) }.count,
                gatewayName: gatewayDevice?.name,
                gatewayMACAddress: gatewayDevice?.macAddress,
                gatewayIP: gatewayIP,
                averageMeshQualityBars: meshQuality,
                wiredBackhaulCount: wiredBackhaulCount,
                wirelessBackhaulCount: wirelessBackhaulCount
            )
        let channelUtilization = parseChannelUtilizationSummary(data)
        let wirelessCongestion = parseWirelessCongestion(clients, channelUtilization: channelUtilization)
        let activitySummary = parseNetworkActivitySummary(data, clients: clients)
        let realtimeSummary = parseRealtimeSummary(clients)
        let proxiedNodes = parseProxiedNodesSummary(data)

        return EeroNetwork(
            id: id,
            name: name,
            nickname: nickname,
            status: status,
            premiumEnabled: premiumEnabled,
            connectedClientsCount: connectedClientsCount,
            connectedGuestClientsCount: connectedGuestClientsCount,
            guestNetworkEnabled: DictionaryValue.bool(in: guestNetworkData, path: ["enabled"])
                ?? DictionaryValue.bool(in: data, path: ["guest_network", "enabled"])
                ?? false,
            guestNetworkName: DictionaryValue.string(in: guestNetworkData, path: ["name"])
                ?? DictionaryValue.string(in: data, path: ["guest_network", "name"]),
            guestNetworkPassword: DictionaryValue.string(in: guestNetworkData, path: ["password"])
                ?? DictionaryValue.string(in: data, path: ["guest_network", "password"]),
            guestNetworkDetails: GuestNetworkDetails(
                enabled: DictionaryValue.bool(in: guestNetworkData, path: ["enabled"]),
                name: DictionaryValue.string(in: guestNetworkData, path: ["name"]),
                password: DictionaryValue.string(in: guestNetworkData, path: ["password"])
            ),
            backupInternetEnabled: DictionaryValue.bool(in: data, path: ["backup_internet_enabled"]),
            resources: resources,
            features: NetworkFeatureState(
                adBlock: DictionaryValue.bool(in: data, path: ["premium_dns", "ad_block_settings", "enabled"]),
                blockMalware: DictionaryValue.bool(in: data, path: ["premium_dns", "dns_policies", "block_malware"]),
                bandSteering: DictionaryValue.bool(in: data, path: ["band_steering"]),
                upnp: DictionaryValue.bool(in: data, path: ["upnp"]),
                wpa3: DictionaryValue.bool(in: data, path: ["wpa3"]),
                threadEnabled: DictionaryValue.bool(in: data, path: ["thread", "enabled"]),
                sqm: DictionaryValue.bool(in: data, path: ["sqm"]),
                ipv6Upstream: DictionaryValue.bool(in: data, path: ["ipv6_upstream"])
            ),
            ddns: NetworkDDNSSummary(
                enabled: DictionaryValue.bool(in: data, path: ["ddns", "enabled"]),
                subdomain: DictionaryValue.string(in: data, path: ["ddns", "subdomain"])
            ),
            health: NetworkHealthSummary(
                internetStatus: DictionaryValue.string(in: data, path: ["health", "internet", "status"]),
                internetUp: DictionaryValue.bool(in: data, path: ["health", "internet", "isp_up"]),
                eeroNetworkStatus: DictionaryValue.string(in: data, path: ["health", "eero_network", "status"])
            ),
            diagnostics: NetworkDiagnosticsSummary(
                status: DictionaryValue.string(in: data, path: ["diagnostics", "status"])
            ),
            updates: NetworkUpdateSummary(
                hasUpdate: DictionaryValue.bool(in: data, path: ["updates", "has_update"])
                    ?? DictionaryValue.bool(in: data, path: ["updates", "update_required"]),
                canUpdateNow: DictionaryValue.bool(in: data, path: ["updates", "can_update_now"]),
                targetFirmware: DictionaryValue.string(in: data, path: ["updates", "target_firmware"]),
                minRequiredFirmware: DictionaryValue.string(in: data, path: ["updates", "min_required_firmware"]),
                updateToFirmware: DictionaryValue.string(in: data, path: ["updates", "update_to_firmware"]),
                updateStatus: DictionaryValue.string(in: data, path: ["updates", "update_status"]),
                preferredUpdateHour: DictionaryValue.int(in: data, path: ["updates", "preferred_update_hour"]),
                scheduledUpdateTime: stringValue(DictionaryValue.value(in: data, path: ["updates", "scheduled_update_time"])),
                lastUpdateStarted: stringValue(DictionaryValue.value(in: data, path: ["updates", "last_update_started"]))
            ),
            speed: NetworkSpeedSummary(
                measuredDownValue: DictionaryValue.double(in: data, path: ["speed", "down", "value"]) ?? speedTestRecord?.downMbps,
                measuredDownUnits: DictionaryValue.string(in: data, path: ["speed", "down", "units"]) ?? "Mbps",
                measuredUpValue: DictionaryValue.double(in: data, path: ["speed", "up", "value"]) ?? speedTestRecord?.upMbps,
                measuredUpUnits: DictionaryValue.string(in: data, path: ["speed", "up", "units"]) ?? "Mbps",
                measuredAt: stringValue(DictionaryValue.value(in: data, path: ["speed", "date"])) ?? speedTestRecord?.date,
                latestSpeedTest: speedTestRecord
            ),
            support: NetworkSupportSummary(
                supportPhone: DictionaryValue.string(in: data, path: ["support", "support_phone"]),
                contactURL: DictionaryValue.string(in: data, path: ["support", "contact_url"]),
                helpURL: DictionaryValue.string(in: data, path: ["support", "help_url"]),
                emailWebFormURL: DictionaryValue.string(in: data, path: ["support", "email_web_form_url"]),
                name: DictionaryValue.string(in: data, path: ["support", "name"])
            ),
            acCompatibility: parseACCompatibility(data["ac_compat"]),
            security: NetworkSecuritySummary(
                blacklistedDeviceCount: blacklistedDevices.count,
                blacklistedDeviceNames: blacklistedNames
            ),
            routing: NetworkRoutingSummary(
                reservationCount: reservationData.count,
                forwardCount: forwardData.count,
                pinholeCount: routingPinholes.count,
                reservations: reservationData.map(Self.parseReservation),
                forwards: forwardData.map(Self.parseForward)
            ),
            insights: NetworkInsightsSummary(
                available: insightsAvailable,
                lastError: nil
            ),
            threadDetails: threadDetails,
            burstReporters: burstSummary,
            gatewayIP: gatewayIP,
            mesh: meshSummary,
            wirelessCongestion: wirelessCongestion,
            activity: activitySummary,
            realtime: realtimeSummary,
            channelUtilization: channelUtilization,
            proxiedNodes: proxiedNodes,
            clients: clients,
            profiles: profiles,
            devices: devices,
            lastUpdated: Date()
        )
    }

    private static func parseClient(_ data: [String: Any]) -> EeroClient {
        let url = DictionaryValue.string(in: data, path: ["url"])
        let id = stableIdentifier(
            primary: DictionaryValue.id(fromURL: url ?? DictionaryValue.string(in: data, path: ["resource_url"])),
            fallbacks: [
                DictionaryValue.string(in: data, path: ["mac"]),
                DictionaryValue.string(in: data, path: ["ip"]),
                DictionaryValue.string(in: data, path: ["ipv4"]),
                DictionaryValue.string(in: data, path: ["hostname"]),
                DictionaryValue.string(in: data, path: ["nickname"])
            ],
            prefix: "client"
        )
        let name = DictionaryValue.string(in: data, path: ["nickname"])
            ?? DictionaryValue.string(in: data, path: ["hostname"])
            ?? DictionaryValue.string(in: data, path: ["mac"])
            ?? "Client"

        return EeroClient(
            id: id,
            name: name,
            mac: DictionaryValue.string(in: data, path: ["mac"]),
            ip: DictionaryValue.string(in: data, path: ["ip"]) ?? DictionaryValue.string(in: data, path: ["ipv4"]),
            connected: DictionaryValue.bool(in: data, path: ["connected"]) ?? false,
            paused: DictionaryValue.bool(in: data, path: ["paused"]) ?? false,
            wireless: DictionaryValue.bool(in: data, path: ["wireless"]),
            isGuest: DictionaryValue.bool(in: data, path: ["is_guest"]) ?? false,
            connectionType: DictionaryValue.string(in: data, path: ["connection_type"]),
            signal: DictionaryValue.string(in: data, path: ["connectivity", "signal"]),
            signalAverage: DictionaryValue.string(in: data, path: ["connectivity", "signal_avg"]),
            scoreBars: DictionaryValue.int(in: data, path: ["connectivity", "score_bars"]),
            channel: DictionaryValue.int(in: data, path: ["channel"]) ?? DictionaryValue.int(in: data, path: ["connectivity", "channel"]),
            blacklisted: DictionaryValue.bool(in: data, path: ["blacklisted"]),
            deviceType: DictionaryValue.string(in: data, path: ["device_type"])
                ?? DictionaryValue.string(in: data, path: ["manufacturer_device_type_id"]),
            manufacturer: DictionaryValue.string(in: data, path: ["manufacturer"]),
            lastActive: stringValue(DictionaryValue.value(in: data, path: ["last_active"])),
            isPrivate: DictionaryValue.bool(in: data, path: ["is_private"]),
            interfaceFrequency: stringValue(DictionaryValue.value(in: data, path: ["interface", "frequency"])),
            interfaceFrequencyUnit: DictionaryValue.string(in: data, path: ["interface", "frequency_unit"]),
            rxChannelWidth: DictionaryValue.string(in: data, path: ["connectivity", "rx_rate_info", "channel_width"]),
            txChannelWidth: DictionaryValue.string(in: data, path: ["connectivity", "tx_rate_info", "channel_width"]),
            rxRateMbps: numericValue(
                DictionaryValue.value(in: data, path: ["connectivity", "rx_rate_info", "rate_mbps"])
                    ?? DictionaryValue.value(in: data, path: ["connectivity", "rx_rate_info", "mbps"])
                    ?? DictionaryValue.value(in: data, path: ["connectivity", "rx_rate_info", "rate"])
            ),
            txRateMbps: numericValue(
                DictionaryValue.value(in: data, path: ["connectivity", "tx_rate_info", "rate_mbps"])
                    ?? DictionaryValue.value(in: data, path: ["connectivity", "tx_rate_info", "mbps"])
                    ?? DictionaryValue.value(in: data, path: ["connectivity", "tx_rate_info", "rate"])
            ),
            usageDownMbps: numericValue(DictionaryValue.value(in: data, path: ["usage", "down_mbps"])),
            usageUpMbps: numericValue(DictionaryValue.value(in: data, path: ["usage", "up_mbps"])),
            usageDayDownload: nil,
            usageDayUpload: nil,
            usageWeekDownload: nil,
            usageWeekUpload: nil,
            usageMonthDownload: nil,
            usageMonthUpload: nil,
            sourceLocation: DictionaryValue.string(in: data, path: ["source", "location"]),
            sourceURL: DictionaryValue.string(in: data, path: ["source", "url"]),
            resources: DictionaryValue.stringMap(in: data, path: ["resources"])
        )
    }

    private static func parseProfile(_ data: [String: Any], adBlockProfiles: Set<String>) -> EeroProfile {
        let url = DictionaryValue.string(in: data, path: ["url"])
        let id = stableIdentifier(
            primary: DictionaryValue.id(fromURL: url),
            fallbacks: [url, DictionaryValue.string(in: data, path: ["name"])],
            prefix: "profile"
        )
        let name = DictionaryValue.string(in: data, path: ["name"]) ?? "Profile"

        return EeroProfile(
            id: id,
            name: name,
            paused: DictionaryValue.bool(in: data, path: ["paused"]) ?? false,
            adBlock: url.map { adBlockProfiles.contains($0) },
            blockedApplications: DictionaryValue.value(in: data, path: ["premium_dns", "blocked_applications"]) as? [String] ?? [],
            filters: ProfileFilterState(
                blockAdult: DictionaryValue.bool(in: data, path: ["unified_content_filters", "dns_policies", "block_pornographic_content"]),
                blockGaming: DictionaryValue.bool(in: data, path: ["unified_content_filters", "dns_policies", "block_gaming_content"]),
                blockMessaging: DictionaryValue.bool(in: data, path: ["unified_content_filters", "dns_policies", "block_messaging_content"]),
                blockShopping: DictionaryValue.bool(in: data, path: ["unified_content_filters", "dns_policies", "block_shopping_content"]),
                blockSocial: DictionaryValue.bool(in: data, path: ["unified_content_filters", "dns_policies", "block_social_content"]),
                blockStreaming: DictionaryValue.bool(in: data, path: ["unified_content_filters", "dns_policies", "block_streaming_content"]),
                blockViolent: DictionaryValue.bool(in: data, path: ["unified_content_filters", "dns_policies", "block_violent_content"])
            ),
            resources: DictionaryValue.stringMap(in: data, path: ["resources"])
        )
    }

    private static func parseDevice(_ data: [String: Any]) -> EeroDevice {
        let url = DictionaryValue.string(in: data, path: ["url"])
        let id = stableIdentifier(
            primary: DictionaryValue.id(fromURL: url),
            fallbacks: [
                DictionaryValue.string(in: data, path: ["mac_address"]),
                DictionaryValue.string(in: data, path: ["serial"]),
                DictionaryValue.string(in: data, path: ["ip_address"]),
                DictionaryValue.string(in: data, path: ["ip"]),
                DictionaryValue.string(in: data, path: ["location"]),
                DictionaryValue.string(in: data, path: ["nickname"])
            ],
            prefix: "eero"
        )

        let portDetails = DictionaryValue.dictArray(in: data, path: ["port_details"])
            .map { detail in
                let position = DictionaryValue.int(in: detail, path: ["position"])
                let portName = DictionaryValue.string(in: detail, path: ["port_name"])
                let ethernetAddress = DictionaryValue.string(in: detail, path: ["ethernet_address"])
                let stableID = stableIdentifier(
                    primary: "\(id)-port-\(position.map(String.init) ?? "?")",
                    fallbacks: [portName, ethernetAddress],
                    prefix: "port"
                )
                return EeroPortDetailSummary(id: stableID, position: position, portName: portName, ethernetAddress: ethernetAddress)
            }

        let legacyEthernetStatuses = DictionaryValue.dictArray(in: data, path: ["ethernet_status", "statuses"]).map { status in
            let interfaceNumber = DictionaryValue.int(in: status, path: ["interfaceNumber"])
            let portName = DictionaryValue.string(in: status, path: ["port_name"])
            let hasCarrier = DictionaryValue.bool(in: status, path: ["hasCarrier"])
            let isWanPort = DictionaryValue.bool(in: status, path: ["isWanPort"])
            let speedTag = DictionaryValue.string(in: status, path: ["speed"])
            let powerSaving = DictionaryValue.bool(in: status, path: ["power_saving"])
            let originalSpeed = DictionaryValue.string(in: status, path: ["original_speed"])

            let neighborMeta = DictionaryValue.dict(in: status, path: ["neighbor", "metadata"]) ?? [:]
            let neighborName = DictionaryValue.string(in: neighborMeta, path: ["location"])
            let neighborURL = DictionaryValue.string(in: neighborMeta, path: ["url"])
            let neighborPortName = DictionaryValue.string(in: neighborMeta, path: ["port_name"])
            let neighborPort = DictionaryValue.int(in: neighborMeta, path: ["port"])

            let statusID = stableIdentifier(
                primary: "\(id)-if-\(interfaceNumber.map(String.init) ?? "?")",
                fallbacks: [portName, speedTag, neighborURL, neighborName],
                prefix: "eth"
            )

            return EeroEthernetPortStatus(
                id: statusID,
                interfaceNumber: interfaceNumber,
                portName: portName,
                hasCarrier: hasCarrier,
                isWanPort: isWanPort,
                speedTag: speedTag,
                powerSaving: powerSaving,
                originalSpeed: originalSpeed,
                neighborName: neighborName,
                neighborURL: neighborURL,
                neighborPortName: neighborPortName,
                neighborPort: neighborPort,
                connectionKind: nil,
                connectionType: nil
            )
        }

        let connectionEthernetStatuses = DictionaryValue.dictArray(in: data, path: ["connections", "ports", "interfaces"]).map { interface in
            let interfaceNumber = DictionaryValue.int(in: interface, path: ["interface_number"])
                ?? DictionaryValue.int(in: interface, path: ["interfaceNumber"])
            let portName = DictionaryValue.string(in: interface, path: ["name"])
                ?? DictionaryValue.string(in: interface, path: ["port_name"])
            let networkType = DictionaryValue.string(in: interface, path: ["network_type"])
                ?? DictionaryValue.string(in: interface, path: ["network_type", "value"])
            let isWanPort = networkType?.lowercased().contains("wan")
            let speedTag = DictionaryValue.string(in: interface, path: ["negotiated_speed", "tag"])
                ?? DictionaryValue.string(in: interface, path: ["negotiated_speed", "name"])
                ?? DictionaryValue.string(in: interface, path: ["supported_speed", "tag"])
                ?? DictionaryValue.string(in: interface, path: ["supported_speed", "name"])

            let connectionStatus = DictionaryValue.dict(in: interface, path: ["connection_status"]) ?? [:]
            let metadata = DictionaryValue.dict(in: connectionStatus, path: ["metadata"]) ?? [:]
            let advancedAttributes = DictionaryValue.dict(in: metadata, path: ["advanced_attributes"]) ?? [:]

            let connectionKind = DictionaryValue.string(in: connectionStatus, path: ["kind"])
                ?? DictionaryValue.string(in: connectionStatus, path: ["type"])
                ?? DictionaryValue.string(in: connectionStatus, path: ["connection_type"])
            let connectionType = enumLabel(
                from: DictionaryValue.value(in: advancedAttributes, path: ["connection_type"])
                    ?? DictionaryValue.value(in: metadata, path: ["connection_type"])
                    ?? DictionaryValue.value(in: connectionStatus, path: ["connection_type"])
            )

            let neighborName = DictionaryValue.string(in: metadata, path: ["location"])
                ?? DictionaryValue.string(in: metadata, path: ["display_name"])
                ?? DictionaryValue.string(in: metadata, path: ["model_name"])
            let neighborURL = DictionaryValue.string(in: metadata, path: ["url"])
            let neighborPortName = DictionaryValue.string(in: metadata, path: ["port_name"])
            let neighborPort = DictionaryValue.int(in: metadata, path: ["port"])

            let normalizedKind = (connectionKind ?? "").lowercased()
            let hasCarrier: Bool?
            if normalizedKind.isEmpty {
                hasCarrier = (neighborName != nil || neighborURL != nil || connectionType != nil)
            } else {
                hasCarrier = !(normalizedKind.contains("notconnected")
                    || normalizedKind.contains("not_connected")
                    || normalizedKind.contains("unknown")
                    || normalizedKind.contains("disconnected"))
            }

            let statusID = stableIdentifier(
                primary: "\(id)-if-\(interfaceNumber.map(String.init) ?? "?")",
                fallbacks: [portName, speedTag, neighborURL, neighborName],
                prefix: "eth"
            )

            return EeroEthernetPortStatus(
                id: statusID,
                interfaceNumber: interfaceNumber,
                portName: portName,
                hasCarrier: hasCarrier,
                isWanPort: isWanPort,
                speedTag: speedTag,
                powerSaving: nil,
                originalSpeed: nil,
                neighborName: neighborName,
                neighborURL: neighborURL,
                neighborPortName: neighborPortName,
                neighborPort: neighborPort,
                connectionKind: connectionKind,
                connectionType: connectionType
            )
        }

        let ethernetStatuses = connectionEthernetStatuses.isEmpty ? legacyEthernetStatuses : connectionEthernetStatuses

        let wirelessConnectionRows = DictionaryValue.dictArray(in: data, path: ["connections", "wireless_devices"])
        var wirelessAttachments: [EeroWirelessAttachmentSummary] = []
        wirelessAttachments.reserveCapacity(wirelessConnectionRows.count)

        for attachment in wirelessConnectionRows {
            let metadata = DictionaryValue.dict(in: attachment, path: ["metadata"]) ?? attachment
            let displayName = DictionaryValue.string(in: metadata, path: ["display_name"])
                ?? DictionaryValue.string(in: metadata, path: ["location"])
            let url = DictionaryValue.string(in: metadata, path: ["url"])
            let kind = DictionaryValue.string(in: attachment, path: ["kind"])
                ?? DictionaryValue.string(in: attachment, path: ["type"])
                ?? DictionaryValue.string(in: metadata, path: ["kind"])
                ?? DictionaryValue.string(in: metadata, path: ["type"])
            let model = DictionaryValue.string(in: metadata, path: ["model"])
                ?? DictionaryValue.string(in: metadata, path: ["model_name"])
            let deviceType = DictionaryValue.string(in: metadata, path: ["device_type"])

            guard displayName != nil || url != nil || model != nil || deviceType != nil else {
                continue
            }

            let stableID = stableIdentifier(
                primary: DictionaryValue.id(fromURL: url),
                fallbacks: [displayName, url, model, deviceType],
                prefix: "wireless"
            )

            wirelessAttachments.append(
                EeroWirelessAttachmentSummary(
                    id: stableID,
                    displayName: displayName,
                    url: url,
                    kind: kind,
                    model: model,
                    deviceType: deviceType
                )
            )
        }

        return EeroDevice(
            id: id,
            name: DictionaryValue.string(in: data, path: ["location"])
                ?? DictionaryValue.string(in: data, path: ["nickname"])
                ?? "eero",
            model: DictionaryValue.string(in: data, path: ["model"]),
            modelNumber: DictionaryValue.string(in: data, path: ["model_number"]),
            serial: DictionaryValue.string(in: data, path: ["serial"]),
            macAddress: DictionaryValue.string(in: data, path: ["mac_address"]),
            isGateway: DictionaryValue.bool(in: data, path: ["gateway"]) ?? false,
            status: DictionaryValue.string(in: data, path: ["status"]),
            statusLightEnabled: DictionaryValue.bool(in: data, path: ["led_on"]),
            statusLightBrightness: DictionaryValue.int(in: data, path: ["led_brightness"]),
            updateAvailable: DictionaryValue.bool(in: data, path: ["update_available"]),
            ipAddress: DictionaryValue.string(in: data, path: ["ip_address"]) ?? DictionaryValue.string(in: data, path: ["ip"]),
            osVersion: DictionaryValue.string(in: data, path: ["os_version"]),
            lastRebootAt: stringValue(DictionaryValue.value(in: data, path: ["last_reboot"])),
            connectedClientCount: DictionaryValue.int(in: data, path: ["connected_clients_count"]),
            connectedClientNames: nil,
            connectedWiredClientCount: DictionaryValue.int(in: data, path: ["connected_wired_clients_count"]),
            connectedWirelessClientCount: DictionaryValue.int(in: data, path: ["connected_wireless_clients_count"]),
            meshQualityBars: DictionaryValue.int(in: data, path: ["mesh_quality_bars"]),
            wiredBackhaul: DictionaryValue.bool(in: data, path: ["wired"]),
            wifiBands: (DictionaryValue.value(in: data, path: ["bands"]) as? [String]) ?? [],
            portDetails: portDetails,
            ethernetStatuses: ethernetStatuses,
            wirelessAttachments: wirelessAttachments.isEmpty ? nil : wirelessAttachments,
            usageDayDownload: nil,
            usageDayUpload: nil,
            usageWeekDownload: nil,
            usageWeekUpload: nil,
            usageMonthDownload: nil,
            usageMonthUpload: nil,
            supportExpired: DictionaryValue.bool(in: data, path: ["update_status", "support_expired"]),
            supportExpirationString: DictionaryValue.string(in: data, path: ["update_status", "support_expiration_string"]),
            resources: DictionaryValue.stringMap(in: data, path: ["resources"])
        )
    }

    private static func parseReservation(_ data: [String: Any]) -> NetworkReservation {
        let url = DictionaryValue.string(in: data, path: ["url"])
        return NetworkReservation(
            id: stableIdentifier(
                primary: DictionaryValue.id(fromURL: url),
                fallbacks: [url, DictionaryValue.string(in: data, path: ["ip"]), DictionaryValue.string(in: data, path: ["mac"])],
                prefix: "reservation"
            ),
            description: DictionaryValue.string(in: data, path: ["description"]),
            ip: DictionaryValue.string(in: data, path: ["ip"]),
            mac: DictionaryValue.string(in: data, path: ["mac"])
        )
    }

    private static func parseForward(_ data: [String: Any]) -> NetworkPortForward {
        let url = DictionaryValue.string(in: data, path: ["url"])
        return NetworkPortForward(
            id: stableIdentifier(
                primary: DictionaryValue.id(fromURL: url),
                fallbacks: [
                    url,
                    DictionaryValue.string(in: data, path: ["ip"]),
                    DictionaryValue.string(in: data, path: ["description"]),
                    DictionaryValue.string(in: data, path: ["protocol"])
                ],
                prefix: "forward"
            ),
            description: DictionaryValue.string(in: data, path: ["description"]),
            ip: DictionaryValue.string(in: data, path: ["ip"]),
            gatewayPort: DictionaryValue.int(in: data, path: ["gateway_port"]),
            clientPort: DictionaryValue.int(in: data, path: ["client_port"]),
            protocolName: DictionaryValue.string(in: data, path: ["protocol"]),
            enabled: DictionaryValue.bool(in: data, path: ["enabled"])
        )
    }

    private static func parseACCompatibility(_ value: Any?) -> NetworkACCompatibilitySummary {
        if let dict = value as? [String: Any] {
            return NetworkACCompatibilitySummary(
                enabled: DictionaryValue.bool(in: dict, path: ["enabled"]) ?? DictionaryValue.bool(in: dict, path: ["value"]),
                state: DictionaryValue.string(in: dict, path: ["state"])
            )
        }
        if let boolValue = value as? Bool {
            return NetworkACCompatibilitySummary(enabled: boolValue, state: nil)
        }
        if let number = value as? NSNumber {
            return NetworkACCompatibilitySummary(enabled: number.boolValue, state: nil)
        }
        return NetworkACCompatibilitySummary(enabled: nil, state: nil)
    }

    private static func parseSpeedTestRecord(_ value: Any?) -> SpeedTestRecord? {
        if let rows = value as? [[String: Any]], let first = rows.first {
            return SpeedTestRecord(
                upMbps: DictionaryValue.double(in: first, path: ["up_mbps"]),
                downMbps: DictionaryValue.double(in: first, path: ["down_mbps"]),
                date: stringValue(DictionaryValue.value(in: first, path: ["date"]))
            )
        }

        if let dict = value as? [String: Any] {
            let upMbps = DictionaryValue.double(in: dict, path: ["up_mbps"])
                ?? DictionaryValue.double(in: dict, path: ["up", "value"])
            let downMbps = DictionaryValue.double(in: dict, path: ["down_mbps"])
                ?? DictionaryValue.double(in: dict, path: ["down", "value"])
            let date = stringValue(DictionaryValue.value(in: dict, path: ["date"]))
            if upMbps != nil || downMbps != nil || date != nil {
                return SpeedTestRecord(upMbps: upMbps, downMbps: downMbps, date: date)
            }
        }

        return nil
    }

    private static func parseThreadDetails(_ data: [String: Any]) -> ThreadNetworkDetails? {
        let threadData = DictionaryValue.dict(in: data, path: ["thread"]) ?? [:]
        let details = ThreadNetworkDetails(
            name: DictionaryValue.string(in: threadData, path: ["name"]),
            channel: DictionaryValue.int(in: threadData, path: ["channel"]),
            panID: DictionaryValue.string(in: threadData, path: ["pan_id"]),
            xpanID: DictionaryValue.string(in: threadData, path: ["xpan_id"]),
            commissioningCredential: DictionaryValue.string(in: threadData, path: ["commissioning_credential"]),
            activeOperationalDataset: DictionaryValue.string(in: threadData, path: ["active_operational_dataset"])
        )

        if details.name == nil,
           details.channel == nil,
           details.panID == nil,
           details.xpanID == nil,
           details.commissioningCredential == nil,
           details.activeOperationalDataset == nil {
            return nil
        }
        return details
    }

    private static func parseBurstReporterSummary(_ data: [String: Any]) -> BurstReporterSummary? {
        guard let burstData = DictionaryValue.dict(in: data, path: ["burst_reporters"]) else {
            return nil
        }
        return BurstReporterSummary(status: DictionaryValue.string(in: burstData, path: ["status"]))
    }

    private static func usageByResourceID(in data: [String: Any], path: [String]) -> [String: (download: Int?, upload: Int?)] {
        let rows = usageRows(in: data, path: path)
        var summary: [String: (download: Int?, upload: Int?)] = [:]

        for row in rows {
            guard let resourceID = resourceKeyForUsageRow(row) else {
                continue
            }

            summary[resourceID] = (
                download: integerValue(DictionaryValue.value(in: row, path: ["download"])),
                upload: integerValue(DictionaryValue.value(in: row, path: ["upload"]))
            )
        }

        return summary
    }

    private static func usageByResourceID(
        in data: [String: Any],
        candidatePaths: [[String]]
    ) -> [String: (download: Int?, upload: Int?)] {
        for path in candidatePaths {
            let values = usageByResourceID(in: data, path: path)
            if !values.isEmpty {
                return values
            }
        }
        return [:]
    }

    private static func usageRows(in data: [String: Any], path: [String]) -> [[String: Any]] {
        let directRows = DictionaryValue.dictArray(in: data, path: path)
        if !directRows.isEmpty {
            return directRows
        }
        if let dict = DictionaryValue.dict(in: data, path: path),
           let values = dict["values"] as? [[String: Any]] {
            return values
        }
        return []
    }

    private static func resourceKeyForUsageRow(_ row: [String: Any]) -> String? {
        if let url = DictionaryValue.string(in: row, path: ["url"]) {
            let id = DictionaryValue.id(fromURL: url)
            if !id.isEmpty {
                return id
            }
        }
        if let mac = DictionaryValue.string(in: row, path: ["mac"]), !mac.isEmpty {
            return mac
        }
        if let identifier = DictionaryValue.string(in: row, path: ["id"]), !identifier.isEmpty {
            return identifier
        }
        return nil
    }

    private static func usageByKey(_ key: String, from usage: [String: (download: Int?, upload: Int?)]) -> (download: Int?, upload: Int?)? {
        if let direct = usage[key] {
            return direct
        }
        let normalized = normalizeKey(key)
        guard !normalized.isEmpty else {
            return nil
        }
        return usage.first(where: { normalizeKey($0.key) == normalized })?.value
    }

    private static func firstUsageValue(
        in usage: [String: (download: Int?, upload: Int?)],
        keys: [String?]
    ) -> (download: Int?, upload: Int?)? {
        for key in keys {
            guard let key, !key.isEmpty else { continue }
            if let value = usageByKey(key, from: usage) {
                return value
            }
        }
        return nil
    }

    private static func normalizeUsageLookup(
        _ usage: [String: (download: Int?, upload: Int?)]
    ) -> [String: (download: Int?, upload: Int?)] {
        var normalized: [String: (download: Int?, upload: Int?)] = [:]
        for (key, value) in usage {
            let normalizedKey = normalizeKey(key)
            guard !normalizedKey.isEmpty else { continue }
            normalized[normalizedKey] = value
        }
        return normalized
    }

    private static func usageValue(
        for client: EeroClient,
        direct: [String: (download: Int?, upload: Int?)],
        normalized: [String: (download: Int?, upload: Int?)]
    ) -> (download: Int?, upload: Int?)? {
        if let value = usageByKey(client.id, from: direct) {
            return value
        }

        if let mac = client.mac,
           let value = normalized[normalizeKey(mac)] {
            return value
        }

        if let sourceURL = client.sourceURL,
           let value = normalized[normalizeKey(DictionaryValue.id(fromURL: sourceURL))] {
            return value
        }

        return nil
    }

    private static func normalizeKey(_ value: String?) -> String {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return ""
        }

        let lowered = value.lowercased()
        let scalarSet = CharacterSet.alphanumerics
        let compact = String(lowered.unicodeScalars.filter { scalarSet.contains($0) })
        if !compact.isEmpty {
            return compact
        }
        return lowered
    }

    private static func trimStablePrefix(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        guard let separator = value.firstIndex(of: "-"),
              separator != value.startIndex else {
            return value
        }

        let suffixStart = value.index(after: separator)
        guard suffixStart < value.endIndex else {
            return value
        }

        let suffix = String(value[suffixStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return suffix.isEmpty ? value : suffix
    }

    private static func stableIdentifier(primary: String?, fallbacks: [String?], prefix: String) -> String {
        let candidates = [primary] + fallbacks
        for candidate in candidates {
            let normalized = normalizeKey(candidate)
            if !normalized.isEmpty {
                return "\(prefix)-\(normalized)"
            }
        }
        return "\(prefix)-unknown"
    }

    private static func parseNetworkActivitySummary(_ data: [String: Any], clients: [EeroClient]) -> NetworkActivitySummary? {
        let day = usageTotals(usageRows(in: data, path: ["activity", "network", "data_usage_day"]))
        let week = usageTotals(usageRows(in: data, path: ["activity", "network", "data_usage_week"]))
        let month = usageTotals(usageRows(in: data, path: ["activity", "network", "data_usage_month"]))
        let busiestDevices = parseTopDeviceUsage(data, clients: clients)
        let busiestTimelines = parseDeviceUsageTimelines(data, clients: clients, topDevices: busiestDevices)

        if day.download == nil, day.upload == nil,
           week.download == nil, week.upload == nil,
           month.download == nil, month.upload == nil,
           busiestDevices.isEmpty,
           busiestTimelines.isEmpty {
            return nil
        }

        return NetworkActivitySummary(
            networkDataUsageDayDownload: day.download,
            networkDataUsageDayUpload: day.upload,
            networkDataUsageWeekDownload: week.download,
            networkDataUsageWeekUpload: week.upload,
            networkDataUsageMonthDownload: month.download,
            networkDataUsageMonthUpload: month.upload,
            busiestDevices: busiestDevices,
            busiestDeviceTimelines: busiestTimelines.isEmpty ? nil : busiestTimelines
        )
    }

    private static func parseTopDeviceUsage(_ data: [String: Any], clients: [EeroClient]) -> [TopDeviceUsage] {
        let dayRows = usageRows(in: data, path: ["activity", "devices", "data_usage_day"])
        let weekRows = usageRows(in: data, path: ["activity", "devices", "data_usage_week"])
        let monthRows = usageRows(in: data, path: ["activity", "devices", "data_usage_month"])

        let day = usageByResourceID(in: data, path: ["activity", "devices", "data_usage_day"])
        let week = usageByResourceID(in: data, path: ["activity", "devices", "data_usage_week"])
        let month = usageByResourceID(in: data, path: ["activity", "devices", "data_usage_month"])

        let keys = Set(day.keys).union(week.keys).union(month.keys)
        guard !keys.isEmpty else {
            return []
        }

        var clientLookup: [String: EeroClient] = [:]
        for client in clients {
            let candidates = [client.id, client.mac, client.sourceURL.map { DictionaryValue.id(fromURL: $0) }]
            for candidate in candidates {
                let normalized = normalizeKey(candidate)
                guard !normalized.isEmpty else { continue }
                if clientLookup[normalized] == nil {
                    clientLookup[normalized] = client
                }
            }
        }

        var metadataLookup: [String: (name: String?, mac: String?, manufacturer: String?, deviceType: String?)] = [:]
        for row in dayRows + weekRows + monthRows {
            guard let resourceKey = resourceKeyForUsageRow(row) else { continue }
            let normalized = normalizeKey(resourceKey)
            guard !normalized.isEmpty else { continue }

            if metadataLookup[normalized] == nil {
                metadataLookup[normalized] = (
                    name: DictionaryValue.string(in: row, path: ["display_name"])
                        ?? DictionaryValue.string(in: row, path: ["nickname"])
                        ?? DictionaryValue.string(in: row, path: ["hostname"]),
                    mac: DictionaryValue.string(in: row, path: ["mac"]),
                    manufacturer: DictionaryValue.string(in: row, path: ["manufacturer"]),
                    deviceType: DictionaryValue.string(in: row, path: ["device_type"])
                )
            }
        }

        var entries: [TopDeviceUsage] = []
        entries.reserveCapacity(keys.count)

        for key in keys {
            let normalized = normalizeKey(key)
            let client = clientLookup[normalized]
            let metadata = metadataLookup[normalized]

            let name = client?.name
                ?? metadata?.name
                ?? key
            let macAddress = client?.mac ?? metadata?.mac
            let manufacturer = client?.manufacturer ?? metadata?.manufacturer
            let deviceType = client?.deviceType ?? metadata?.deviceType

            entries.append(
                TopDeviceUsage(
                    id: stableIdentifier(primary: key, fallbacks: [macAddress, name], prefix: "usage-device"),
                    name: name,
                    macAddress: macAddress,
                    manufacturer: manufacturer,
                    deviceType: deviceType,
                    dayDownloadBytes: usageByKey(key, from: day)?.download,
                    dayUploadBytes: usageByKey(key, from: day)?.upload,
                    weekDownloadBytes: usageByKey(key, from: week)?.download,
                    weekUploadBytes: usageByKey(key, from: week)?.upload,
                    monthDownloadBytes: usageByKey(key, from: month)?.download,
                    monthUploadBytes: usageByKey(key, from: month)?.upload
                )
            )
        }

        func total(_ entry: TopDeviceUsage, period: String) -> Int {
            switch period {
            case "month":
                return max(0, (entry.monthDownloadBytes ?? 0) + (entry.monthUploadBytes ?? 0))
            case "week":
                return max(0, (entry.weekDownloadBytes ?? 0) + (entry.weekUploadBytes ?? 0))
            default:
                return max(0, (entry.dayDownloadBytes ?? 0) + (entry.dayUploadBytes ?? 0))
            }
        }

        return entries
            .sorted { lhs, rhs in
                let lhsMonth = total(lhs, period: "month")
                let rhsMonth = total(rhs, period: "month")
                if lhsMonth != rhsMonth {
                    return lhsMonth > rhsMonth
                }
                let lhsWeek = total(lhs, period: "week")
                let rhsWeek = total(rhs, period: "week")
                if lhsWeek != rhsWeek {
                    return lhsWeek > rhsWeek
                }
                let lhsDay = total(lhs, period: "day")
                let rhsDay = total(rhs, period: "day")
                if lhsDay != rhsDay {
                    return lhsDay > rhsDay
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .prefix(8)
            .map { $0 }
    }

    private static func parseDeviceUsageTimelines(
        _ data: [String: Any],
        clients: [EeroClient],
        topDevices: [TopDeviceUsage]
    ) -> [DeviceUsageTimeline] {
        let timelineRows = DictionaryValue.dictArray(in: data, path: ["activity", "devices", "device_timelines"])
        guard !timelineRows.isEmpty else {
            return []
        }

        var topLookup: [String: TopDeviceUsage] = [:]
        for device in topDevices {
            let candidates = [device.id, trimStablePrefix(device.id), device.macAddress, device.name]
            for candidate in candidates {
                let normalized = normalizeKey(candidate)
                guard !normalized.isEmpty else { continue }
                if topLookup[normalized] == nil {
                    topLookup[normalized] = device
                }
            }
        }

        var clientLookup: [String: EeroClient] = [:]
        for client in clients {
            let candidates = [client.id, trimStablePrefix(client.id), client.mac, client.sourceURL.map { DictionaryValue.id(fromURL: $0) }]
            for candidate in candidates {
                let normalized = normalizeKey(candidate)
                guard !normalized.isEmpty else { continue }
                if clientLookup[normalized] == nil {
                    clientLookup[normalized] = client
                }
            }
        }

        var timelines: [DeviceUsageTimeline] = []
        timelines.reserveCapacity(timelineRows.count)

        for row in timelineRows {
            let payload = DictionaryValue.value(in: row, path: ["payload"])
            let samples = parseTimelineSamples(from: payload)
            guard !samples.isEmpty else {
                continue
            }

            let resourceKey = DictionaryValue.string(in: row, path: ["resource_key"])
                ?? DictionaryValue.string(in: row, path: ["id"])
                ?? DictionaryValue.string(in: row, path: ["mac"])
                ?? DictionaryValue.string(in: row, path: ["display_name"])
                ?? "timeline"
            let normalizedResource = normalizeKey(resourceKey)
            let top = topLookup[normalizedResource]
            let client = clientLookup[normalizedResource]

            let embeddedDevice = DictionaryValue.dict(in: payload as? [String: Any] ?? [:], path: ["device"]) ?? [:]
            let embeddedName = DictionaryValue.string(in: embeddedDevice, path: ["display_name"])
                ?? DictionaryValue.string(in: embeddedDevice, path: ["nickname"])
                ?? DictionaryValue.string(in: embeddedDevice, path: ["hostname"])
            let embeddedMAC = DictionaryValue.string(in: embeddedDevice, path: ["mac"])

            let macAddress = DictionaryValue.string(in: row, path: ["mac"])
                ?? embeddedMAC
                ?? top?.macAddress
                ?? client?.mac
            let displayName = DictionaryValue.string(in: row, path: ["display_name"])
                ?? embeddedName
                ?? top?.name
                ?? client?.name
                ?? resourceKey

            timelines.append(
                DeviceUsageTimeline(
                    id: stableIdentifier(primary: resourceKey, fallbacks: [macAddress, displayName], prefix: "usage-timeline"),
                    name: displayName,
                    macAddress: macAddress,
                    samples: samples
                )
            )
        }

        return timelines.sorted { lhs, rhs in
            let lhsTotal = lhs.samples.reduce(0) { $0 + max(0, $1.downloadBytes) + max(0, $1.uploadBytes) }
            let rhsTotal = rhs.samples.reduce(0) { $0 + max(0, $1.downloadBytes) + max(0, $1.uploadBytes) }
            if lhsTotal != rhsTotal {
                return lhsTotal > rhsTotal
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func parseTimelineSamples(from payload: Any?) -> [DeviceUsageTimelineSample] {
        if let dict = payload as? [String: Any] {
            if let seriesSamples = parseTimelineSeriesSamples(from: dict), !seriesSamples.isEmpty {
                return seriesSamples
            }
            let fallbackSamples = parseDirectTimelineSamples(from: dict)
            if !fallbackSamples.isEmpty {
                return fallbackSamples
            }
        }

        if let rows = payload as? [[String: Any]], !rows.isEmpty {
            return parseDirectTimelineSamples(from: ["values": rows])
        }

        return []
    }

    private static func parseTimelineSeriesSamples(from payload: [String: Any]) -> [DeviceUsageTimelineSample]? {
        let seriesRows = DictionaryValue.dictArray(in: payload, path: ["series"])
        guard !seriesRows.isEmpty else {
            return nil
        }

        var downloadByTime: [TimeInterval: Int] = [:]
        var uploadByTime: [TimeInterval: Int] = [:]

        for series in seriesRows {
            let rawType = DictionaryValue.string(in: series, path: ["type"])
                ?? DictionaryValue.string(in: series, path: ["data_usage_type"])
                ?? DictionaryValue.string(in: series, path: ["insight_type_name"])
                ?? ""
            let normalizedType = rawType.lowercased()
            let isDownload = normalizedType.contains("download") || normalizedType == "down"
            let isUpload = normalizedType.contains("upload") || normalizedType == "up"
            guard isDownload || isUpload else {
                continue
            }

            let valueRows = DictionaryValue.dictArray(in: series, path: ["values"])
            for value in valueRows {
                guard let timestamp = dateValue(DictionaryValue.value(in: value, path: ["time"])
                    ?? DictionaryValue.value(in: value, path: ["timestamp"])) else {
                    continue
                }
                let sampleValue = max(0, integerValue(DictionaryValue.value(in: value, path: ["value"])) ?? 0)
                let key = timestamp.timeIntervalSince1970
                if isDownload {
                    downloadByTime[key] = sampleValue
                }
                if isUpload {
                    uploadByTime[key] = sampleValue
                }
            }
        }

        let timestamps = Set(downloadByTime.keys).union(uploadByTime.keys).sorted()
        guard !timestamps.isEmpty else {
            return nil
        }

        return timestamps.map { timestamp in
            let date = Date(timeIntervalSince1970: timestamp)
            return DeviceUsageTimelineSample(
                id: stableIdentifier(primary: "\(timestamp)", fallbacks: [], prefix: "timeline-sample"),
                timestamp: date,
                downloadBytes: max(0, downloadByTime[timestamp] ?? 0),
                uploadBytes: max(0, uploadByTime[timestamp] ?? 0)
            )
        }
    }

    private static func parseDirectTimelineSamples(from payload: [String: Any]) -> [DeviceUsageTimelineSample] {
        let rows = usageRows(in: payload, path: ["values"])
        guard !rows.isEmpty else {
            return []
        }

        var samples: [DeviceUsageTimelineSample] = []
        samples.reserveCapacity(rows.count)

        for row in rows {
            guard let timestamp = dateValue(
                DictionaryValue.value(in: row, path: ["time"])
                    ?? DictionaryValue.value(in: row, path: ["timestamp"])
                    ?? DictionaryValue.value(in: row, path: ["date"])
            ) else {
                continue
            }

            let download = max(0, integerValue(DictionaryValue.value(in: row, path: ["download"])) ?? 0)
            let upload = max(0, integerValue(DictionaryValue.value(in: row, path: ["upload"])) ?? 0)
            if download == 0, upload == 0 {
                continue
            }

            samples.append(
                DeviceUsageTimelineSample(
                    id: stableIdentifier(primary: "\(timestamp.timeIntervalSince1970)", fallbacks: [], prefix: "timeline-sample"),
                    timestamp: timestamp,
                    downloadBytes: download,
                    uploadBytes: upload
                )
            )
        }

        return samples.sorted { $0.timestamp < $1.timestamp }
    }

    private static func parseRealtimeSummary(_ clients: [EeroClient]) -> NetworkRealtimeSummary? {
        let activeUsageClients = clients.filter { $0.connected && ($0.usageDownMbps != nil || $0.usageUpMbps != nil) }
        guard !activeUsageClients.isEmpty else {
            return nil
        }

        let downMbps = activeUsageClients.reduce(0.0) { $0 + max(0, $1.usageDownMbps ?? 0) }
        let upMbps = activeUsageClients.reduce(0.0) { $0 + max(0, $1.usageUpMbps ?? 0) }

        return NetworkRealtimeSummary(
            downloadMbps: downMbps,
            uploadMbps: upMbps,
            sourceLabel: "eero client telemetry",
            sampledAt: Date()
        )
    }

    private static func parseProxiedNodesSummary(_ data: [String: Any]) -> ProxiedNodesSummary? {
        guard let proxied = DictionaryValue.dict(in: data, path: ["proxied_nodes"]) else {
            return nil
        }

        let devices = DictionaryValue.dictArray(in: proxied, path: ["devices"])
        let online = devices.filter { device in
            let rawStatus = DictionaryValue.string(in: device, path: ["status"])
                ?? DictionaryValue.string(in: device, path: ["status", "value"])
                ?? ""
            let normalized = rawStatus.lowercased()
            return normalized == "green" || normalized.contains("online")
        }.count

        let offline = devices.filter { device in
            let rawStatus = DictionaryValue.string(in: device, path: ["status"])
                ?? DictionaryValue.string(in: device, path: ["status", "value"])
                ?? ""
            let normalized = rawStatus.lowercased()
            return normalized == "red" || normalized.contains("offline")
        }.count

        return ProxiedNodesSummary(
            enabled: DictionaryValue.bool(in: proxied, path: ["enabled"]),
            totalDevices: devices.count,
            onlineDevices: online,
            offlineDevices: offline
        )
    }

    private static func parseChannelUtilizationSummary(_ data: [String: Any]) -> NetworkChannelUtilizationSummary? {
        let raw = data["channel_utilization"]
        let channelPayload: [String: Any]

        if let dict = raw as? [String: Any] {
            channelPayload = dict
        } else if let rows = raw as? [[String: Any]] {
            channelPayload = ["utilization": rows]
        } else {
            return nil
        }

        let eeroRows = DictionaryValue.dictArray(in: channelPayload, path: ["eeros"])
        var eeroNameLookup: [String: String] = [:]
        for eero in eeroRows {
            let candidateName = DictionaryValue.string(in: eero, path: ["location"])
                ?? DictionaryValue.string(in: eero, path: ["nickname"])
                ?? DictionaryValue.string(in: eero, path: ["name"])
                ?? DictionaryValue.string(in: eero, path: ["model"])
            guard let candidateName, !candidateName.isEmpty else { continue }

            if let numericID = integerValue(DictionaryValue.value(in: eero, path: ["id"])) {
                eeroNameLookup[String(numericID)] = candidateName
            }
            if let stringID = DictionaryValue.string(in: eero, path: ["id"]) {
                eeroNameLookup[stringID] = candidateName
            }
            if let url = DictionaryValue.string(in: eero, path: ["url"]) {
                let key = DictionaryValue.id(fromURL: url)
                if !key.isEmpty {
                    eeroNameLookup[key] = candidateName
                }
            }
        }

        let utilizationRows = DictionaryValue.dictArray(in: channelPayload, path: ["utilization"])
        guard !utilizationRows.isEmpty else {
            return nil
        }

        let radios = utilizationRows.compactMap { row -> ChannelUtilizationRadio? in
            let eeroID = stringValue(DictionaryValue.value(in: row, path: ["eero_id"]))
                ?? stringValue(DictionaryValue.value(in: row, path: ["eeroId"]))
            let bandValue = DictionaryValue.string(in: row, path: ["band"])
                ?? DictionaryValue.string(in: row, path: ["band", "value"])
            let controlChannel = integerValue(DictionaryValue.value(in: row, path: ["channel"]))
            let centerChannel = integerValue(DictionaryValue.value(in: row, path: ["center_channel"]))
            let channelBandwidth = DictionaryValue.string(in: row, path: ["channel_bandwidth"])
            let averageUtilization = integerValue(DictionaryValue.value(in: row, path: ["average_utilization"]))
            let maxUtilization = integerValue(DictionaryValue.value(in: row, path: ["max_utilization"]))
            let p99Utilization = integerValue(DictionaryValue.value(in: row, path: ["p99_utilization"]))
            let frequencyMHz = integerValue(DictionaryValue.value(in: row, path: ["frequency"]))

            let timeSeriesRows = DictionaryValue.dictArray(in: row, path: ["time_series_data"])
            let timeSeries = timeSeriesRows.compactMap { sampleRow -> ChannelUtilizationSample? in
                guard let timestamp = dateFromEpoch(numericValue(DictionaryValue.value(in: sampleRow, path: ["timestamp"]))) else {
                    return nil
                }

                let busy = integerValue(DictionaryValue.value(in: sampleRow, path: ["busy"]))
                let noise = integerValue(DictionaryValue.value(in: sampleRow, path: ["noise"]))
                let rxTx = integerValue(DictionaryValue.value(in: sampleRow, path: ["rx_tx"]))
                let rxOther = integerValue(DictionaryValue.value(in: sampleRow, path: ["rx_other"]))
                let sampleID = stableIdentifier(
                    primary: "\(timestamp.timeIntervalSince1970)-\(busy ?? -1)-\(noise ?? -1)-\(rxTx ?? -1)-\(rxOther ?? -1)",
                    fallbacks: [],
                    prefix: "radio-sample"
                )

                return ChannelUtilizationSample(
                    id: sampleID,
                    timestamp: timestamp,
                    busyPercent: busy,
                    noisePercent: noise,
                    rxTxPercent: rxTx,
                    rxOtherPercent: rxOther
                )
            }

            let radioID = stableIdentifier(
                primary: "\(eeroID ?? "unknown")-\(bandValue ?? "band")-\(controlChannel.map(String.init) ?? "?")",
                fallbacks: [channelBandwidth],
                prefix: "radio"
            )

            return ChannelUtilizationRadio(
                id: radioID,
                eeroID: eeroID,
                eeroName: lookupEeroName(for: eeroID, in: eeroNameLookup),
                band: bandValue,
                controlChannel: controlChannel,
                centerChannel: centerChannel,
                channelBandwidth: channelBandwidth,
                frequencyMHz: frequencyMHz,
                averageUtilization: averageUtilization,
                maxUtilization: maxUtilization,
                p99Utilization: p99Utilization,
                timeSeries: timeSeries
            )
        }

        guard !radios.isEmpty else {
            return nil
        }

        return NetworkChannelUtilizationSummary(
            radios: radios.sorted { lhs, rhs in
                let lhsUtilization = lhs.averageUtilization ?? Int.min
                let rhsUtilization = rhs.averageUtilization ?? Int.min
                if lhsUtilization != rhsUtilization {
                    return lhsUtilization > rhsUtilization
                }
                let lhsMax = lhs.maxUtilization ?? Int.min
                let rhsMax = rhs.maxUtilization ?? Int.min
                return lhsMax > rhsMax
            },
            sampledAt: Date()
        )
    }

    private static func lookupEeroName(for eeroID: String?, in names: [String: String]) -> String? {
        guard let eeroID, !eeroID.isEmpty else {
            return nil
        }
        if let direct = names[eeroID] {
            return direct
        }
        let normalized = normalizeKey(eeroID)
        return names.first { normalizeKey($0.key) == normalized }?.value
    }

    private static func dateFromEpoch(_ epoch: Double?) -> Date? {
        guard let epoch else {
            return nil
        }
        let seconds = epoch > 1_000_000_000_000 ? epoch / 1_000 : epoch
        return Date(timeIntervalSince1970: seconds)
    }

    private static func dateValue(_ value: Any?) -> Date? {
        if let date = value as? Date {
            return date
        }
        if let epoch = numericValue(value) {
            return dateFromEpoch(epoch)
        }
        if let text = stringValue(value)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = isoFormatter.date(from: text) {
                return date
            }
            isoFormatter.formatOptions = [.withInternetDateTime]
            if let date = isoFormatter.date(from: text) {
                return date
            }

            let fallbackFormatter = DateFormatter()
            fallbackFormatter.locale = Locale(identifier: "en_US_POSIX")
            fallbackFormatter.timeZone = TimeZone(secondsFromGMT: 0)
            fallbackFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            if let date = fallbackFormatter.date(from: text) {
                return date
            }
        }
        return nil
    }

    private static func parseWirelessCongestion(
        _ clients: [EeroClient],
        channelUtilization: NetworkChannelUtilizationSummary?
    ) -> WirelessCongestionSummary? {
        let wirelessClients = clients.filter { ($0.wireless ?? false) && $0.connected }
        guard !wirelessClients.isEmpty else {
            return nil
        }

        let scoreBars = wirelessClients.compactMap(\.scoreBars).map(Double.init)
        let signals = wirelessClients.compactMap { parseSignalDBM($0.signal) }

        let poorSignalCount = wirelessClients.filter { client in
            if let signal = parseSignalDBM(client.signal) {
                return signal <= -70
            }
            if let bars = client.scoreBars {
                return bars <= 2
            }
            return false
        }.count

        let estimatedChannelGroups = Dictionary(grouping: wirelessClients) { client -> String in
            let band = deriveBandLabel(client: client) ?? "Unknown"
            let channelText = client.channel.map(String.init) ?? "?"
            return "\(channelText)-\(band)"
        }

        var congestedChannels = estimatedChannelGroups
            .compactMap { key, grouped -> CongestedChannelSummary? in
                guard grouped.count >= 2 else {
                    return nil
                }
                let channel = grouped.first?.channel
                let band = deriveBandLabel(client: grouped.first)
                let averageSignal = average(grouped.compactMap { parseSignalDBM($0.signal) }.map(Double.init))
                return CongestedChannelSummary(
                    key: key,
                    channel: channel,
                    band: band,
                    clientCount: grouped.count,
                    averageSignalDbm: averageSignal.map { Int($0.rounded()) }
                )
            }
            .sorted {
                if $0.clientCount == $1.clientCount {
                    return ($0.averageSignalDbm ?? Int.min) < ($1.averageSignalDbm ?? Int.min)
                }
                return $0.clientCount > $1.clientCount
            }

        if let channelUtilization {
            let clientCountLookup = estimatedChannelGroups.reduce(into: [String: Int]()) { partial, pair in
                partial[pair.key] = pair.value.count
            }

            let radioCongestion = channelUtilization.radios.compactMap { radio -> CongestedChannelSummary? in
                let band = radio.band ?? "Unknown"
                let channel = radio.controlChannel
                let lookupKey = "\(channel.map(String.init) ?? "?")-\(band)"
                let estimatedClients = clientCountLookup[lookupKey] ?? 0
                let utilizationScore = max(0, radio.averageUtilization ?? 0)
                guard utilizationScore > 0 else {
                    return nil
                }
                return CongestedChannelSummary(
                    key: stableIdentifier(primary: "\(lookupKey)-\(radio.eeroID ?? "")", fallbacks: [radio.eeroName], prefix: "channel"),
                    channel: channel,
                    band: band,
                    clientCount: max(estimatedClients, utilizationScore),
                    averageSignalDbm: nil
                )
            }

            if !radioCongestion.isEmpty {
                congestedChannels = radioCongestion.sorted { lhs, rhs in
                    if lhs.clientCount == rhs.clientCount {
                        return (lhs.channel ?? Int.max) < (rhs.channel ?? Int.max)
                    }
                    return lhs.clientCount > rhs.clientCount
                }
            }
        }

        return WirelessCongestionSummary(
            wirelessClientCount: wirelessClients.count,
            poorSignalClientCount: poorSignalCount,
            averageScoreBars: average(scoreBars),
            averageSignalDbm: average(signals.map(Double.init)),
            congestedChannels: Array(congestedChannels.prefix(6))
        )
    }

    private static func deviceStatusIsOnline(_ status: String?) -> Bool {
        guard let normalized = status?.lowercased() else {
            return false
        }
        return normalized.contains("connected")
            || normalized.contains("online")
            || normalized.contains("up")
            || normalized == "ok"
    }

    private static func deriveBandLabel(client: EeroClient?) -> String? {
        guard let client else { return nil }

        if let channel = client.channel {
            switch channel {
            case 1...14:
                return "2.4 GHz"
            case 15...191:
                return "5 GHz"
            default:
                return "6 GHz"
            }
        }

        if let frequency = numericValue(client.interfaceFrequency) {
            if frequency >= 5900 {
                return "6 GHz"
            }
            if frequency >= 4900 {
                return "5 GHz"
            }
            return "2.4 GHz"
        }

        return nil
    }

    private static func parseSignalDBM(_ signal: String?) -> Int? {
        guard let signal else {
            return nil
        }
        let prefix = signal.split(separator: " ").first.map(String.init) ?? signal
        return Int(prefix)
    }

    private static func usageTotals(_ rows: [[String: Any]]) -> (download: Int?, upload: Int?) {
        var downloadValues: [Int] = []
        var uploadValues: [Int] = []

        for row in rows {
            if let down = integerValue(DictionaryValue.value(in: row, path: ["download"])) {
                downloadValues.append(down)
            }
            if let up = integerValue(DictionaryValue.value(in: row, path: ["upload"])) {
                uploadValues.append(up)
            }
        }

        let totalDownload = downloadValues.isEmpty ? nil : downloadValues.reduce(0, +)
        let totalUpload = uploadValues.isEmpty ? nil : uploadValues.reduce(0, +)
        return (download: totalDownload, upload: totalUpload)
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else {
            return nil
        }
        let total = values.reduce(0, +)
        return total / Double(values.count)
    }

    private static func enumLabel(from value: Any?) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let dict = value as? [String: Any] {
            return stringValue(dict["value"])
                ?? stringValue(dict["name"])
                ?? stringValue(dict["tag"])
                ?? stringValue(dict["label"])
        }
        return stringValue(value)
    }

    private static func numericValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string)
        }
        return nil
    }

    private static func integerValue(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            if let int = Int(string) {
                return int
            }
            if let double = Double(string) {
                return Int(double.rounded())
            }
        }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let text = value as? String {
            return text
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }
}
