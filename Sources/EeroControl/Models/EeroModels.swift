import Foundation

struct EeroAccountSnapshot: Codable, Equatable, Sendable {
    var fetchedAt: Date
    var networks: [EeroNetwork]

    var totalConnectedClients: Int {
        networks.reduce(0) { $0 + $1.connectedClientsCount }
    }
}

struct EeroNetwork: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var nickname: String?
    var status: String?
    var premiumEnabled: Bool
    var connectedClientsCount: Int
    var connectedGuestClientsCount: Int
    var guestNetworkEnabled: Bool
    var guestNetworkName: String?
    var guestNetworkPassword: String?
    var guestNetworkDetails: GuestNetworkDetails?
    var backupInternetEnabled: Bool?
    var resources: [String: String]
    var features: NetworkFeatureState
    var ddns: NetworkDDNSSummary
    var health: NetworkHealthSummary
    var diagnostics: NetworkDiagnosticsSummary
    var updates: NetworkUpdateSummary
    var speed: NetworkSpeedSummary
    var support: NetworkSupportSummary
    var acCompatibility: NetworkACCompatibilitySummary
    var security: NetworkSecuritySummary
    var routing: NetworkRoutingSummary
    var insights: NetworkInsightsSummary
    var threadDetails: ThreadNetworkDetails?
    var burstReporters: BurstReporterSummary?
    var gatewayIP: String?
    var mesh: NetworkMeshSummary?
    var wirelessCongestion: WirelessCongestionSummary?
    var activity: NetworkActivitySummary?
    var realtime: NetworkRealtimeSummary?
    var channelUtilization: NetworkChannelUtilizationSummary?
    var proxiedNodes: ProxiedNodesSummary?
    var clients: [EeroClient]
    var profiles: [EeroProfile]
    var devices: [EeroDevice]
    var lastUpdated: Date
}

struct GuestNetworkDetails: Codable, Equatable, Sendable {
    var enabled: Bool?
    var name: String?
    var password: String?
}

struct NetworkFeatureState: Codable, Equatable, Sendable {
    var adBlock: Bool?
    var blockMalware: Bool?
    var bandSteering: Bool?
    var upnp: Bool?
    var wpa3: Bool?
    var threadEnabled: Bool?
    var sqm: Bool?
    var ipv6Upstream: Bool?
}

struct EeroClient: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var mac: String?
    var ip: String?
    var connected: Bool
    var paused: Bool
    var wireless: Bool?
    var isGuest: Bool
    var connectionType: String?
    var signal: String?
    var signalAverage: String?
    var scoreBars: Int?
    var channel: Int?
    var blacklisted: Bool?
    var deviceType: String?
    var manufacturer: String?
    var lastActive: String?
    var isPrivate: Bool?
    var interfaceFrequency: String?
    var interfaceFrequencyUnit: String?
    var rxChannelWidth: String?
    var txChannelWidth: String?
    var rxRateMbps: Double?
    var txRateMbps: Double?
    var usageDownMbps: Double?
    var usageUpMbps: Double?
    var usageDayDownload: Int?
    var usageDayUpload: Int?
    var usageWeekDownload: Int?
    var usageWeekUpload: Int?
    var usageMonthDownload: Int?
    var usageMonthUpload: Int?
    var sourceLocation: String?
    var sourceURL: String?
    var resources: [String: String]
}

struct EeroProfile: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var paused: Bool
    var adBlock: Bool?
    var blockedApplications: [String]
    var filters: ProfileFilterState
    var resources: [String: String]
}

struct ProfileFilterState: Codable, Equatable, Sendable {
    var blockAdult: Bool?
    var blockGaming: Bool?
    var blockMessaging: Bool?
    var blockShopping: Bool?
    var blockSocial: Bool?
    var blockStreaming: Bool?
    var blockViolent: Bool?
}

struct EeroDevice: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var model: String?
    var modelNumber: String?
    var serial: String?
    var macAddress: String?
    var isGateway: Bool
    var status: String?
    var statusLightEnabled: Bool?
    var statusLightBrightness: Int?
    var updateAvailable: Bool?
    var ipAddress: String?
    var osVersion: String?
    var lastRebootAt: String?
    var connectedClientCount: Int?
    var connectedClientNames: [String]?
    var connectedWiredClientCount: Int?
    var connectedWirelessClientCount: Int?
    var meshQualityBars: Int?
    var wiredBackhaul: Bool?
    var wifiBands: [String]
    var portDetails: [EeroPortDetailSummary]
    var ethernetStatuses: [EeroEthernetPortStatus]
    var wirelessAttachments: [EeroWirelessAttachmentSummary]?
    var usageDayDownload: Int?
    var usageDayUpload: Int?
    var usageWeekDownload: Int?
    var usageWeekUpload: Int?
    var usageMonthDownload: Int?
    var usageMonthUpload: Int?
    var supportExpired: Bool?
    var supportExpirationString: String?
    var resources: [String: String]
}

extension EeroNetwork {
    var displayName: String {
        if let nickname, !nickname.isEmpty {
            return "\(name) \"\(nickname)\""
        }
        return name
    }
}

struct NetworkDDNSSummary: Codable, Equatable, Sendable {
    var enabled: Bool?
    var subdomain: String?
}

struct NetworkHealthSummary: Codable, Equatable, Sendable {
    var internetStatus: String?
    var internetUp: Bool?
    var eeroNetworkStatus: String?
}

struct NetworkDiagnosticsSummary: Codable, Equatable, Sendable {
    var status: String?
}

struct NetworkUpdateSummary: Codable, Equatable, Sendable {
    var hasUpdate: Bool?
    var canUpdateNow: Bool?
    var targetFirmware: String?
    var minRequiredFirmware: String?
    var updateToFirmware: String?
    var updateStatus: String?
    var preferredUpdateHour: Int?
    var scheduledUpdateTime: String?
    var lastUpdateStarted: String?
}

struct SpeedTestRecord: Codable, Equatable, Sendable {
    var upMbps: Double?
    var downMbps: Double?
    var date: String?
}

struct NetworkSpeedSummary: Codable, Equatable, Sendable {
    var measuredDownValue: Double?
    var measuredDownUnits: String?
    var measuredUpValue: Double?
    var measuredUpUnits: String?
    var measuredAt: String?
    var latestSpeedTest: SpeedTestRecord?
}

struct NetworkSupportSummary: Codable, Equatable, Sendable {
    var supportPhone: String?
    var contactURL: String?
    var helpURL: String?
    var emailWebFormURL: String?
    var name: String?
}

struct NetworkACCompatibilitySummary: Codable, Equatable, Sendable {
    var enabled: Bool?
    var state: String?
}

struct NetworkSecuritySummary: Codable, Equatable, Sendable {
    var blacklistedDeviceCount: Int
    var blacklistedDeviceNames: [String]
}

struct NetworkReservation: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var description: String?
    var ip: String?
    var mac: String?
}

struct NetworkPortForward: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var description: String?
    var ip: String?
    var gatewayPort: Int?
    var clientPort: Int?
    var protocolName: String?
    var enabled: Bool?
}

struct NetworkRoutingSummary: Codable, Equatable, Sendable {
    var reservationCount: Int
    var forwardCount: Int
    var pinholeCount: Int
    var reservations: [NetworkReservation]
    var forwards: [NetworkPortForward]
}

struct NetworkInsightsSummary: Codable, Equatable, Sendable {
    var available: Bool
    var lastError: String?
}

struct NetworkMeshSummary: Codable, Equatable, Sendable {
    var eeroCount: Int
    var onlineEeroCount: Int
    var gatewayName: String?
    var gatewayMACAddress: String?
    var gatewayIP: String?
    var averageMeshQualityBars: Double?
    var wiredBackhaulCount: Int
    var wirelessBackhaulCount: Int
}

struct CongestedChannelSummary: Codable, Equatable, Sendable, Identifiable {
    var id: String { key }
    var key: String
    var channel: Int?
    var band: String?
    var clientCount: Int
    var averageSignalDbm: Int?
}

struct WirelessCongestionSummary: Codable, Equatable, Sendable {
    var wirelessClientCount: Int
    var poorSignalClientCount: Int
    var averageScoreBars: Double?
    var averageSignalDbm: Double?
    var congestedChannels: [CongestedChannelSummary]
}

struct NetworkActivitySummary: Codable, Equatable, Sendable {
    var networkDataUsageDayDownload: Int?
    var networkDataUsageDayUpload: Int?
    var networkDataUsageWeekDownload: Int?
    var networkDataUsageWeekUpload: Int?
    var networkDataUsageMonthDownload: Int?
    var networkDataUsageMonthUpload: Int?
    var busiestDevices: [TopDeviceUsage]
    var busiestDeviceTimelines: [DeviceUsageTimeline]?
}

struct NetworkRealtimeSummary: Codable, Equatable, Sendable {
    var downloadMbps: Double
    var uploadMbps: Double
    var sourceLabel: String
    var sampledAt: Date
}

struct TopDeviceUsage: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var macAddress: String?
    var manufacturer: String?
    var deviceType: String?
    var dayDownloadBytes: Int?
    var dayUploadBytes: Int?
    var weekDownloadBytes: Int?
    var weekUploadBytes: Int?
    var monthDownloadBytes: Int?
    var monthUploadBytes: Int?
}

struct DeviceUsageTimeline: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var macAddress: String?
    var samples: [DeviceUsageTimelineSample]
}

struct DeviceUsageTimelineSample: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var timestamp: Date
    var downloadBytes: Int
    var uploadBytes: Int
}

struct EeroWirelessAttachmentSummary: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var displayName: String?
    var url: String?
    var kind: String?
    var model: String?
    var deviceType: String?
}

struct EeroPortDetailSummary: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var position: Int?
    var portName: String?
    var ethernetAddress: String?
}

struct EeroEthernetPortStatus: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var interfaceNumber: Int?
    var portName: String?
    var hasCarrier: Bool?
    var isWanPort: Bool?
    var speedTag: String?
    var powerSaving: Bool?
    var originalSpeed: String?
    var neighborName: String?
    var neighborURL: String?
    var neighborPortName: String?
    var neighborPort: Int?
    var connectionKind: String?
    var connectionType: String?
}

struct ProxiedNodesSummary: Codable, Equatable, Sendable {
    var enabled: Bool?
    var totalDevices: Int
    var onlineDevices: Int
    var offlineDevices: Int
}

struct NetworkChannelUtilizationSummary: Codable, Equatable, Sendable {
    var radios: [ChannelUtilizationRadio]
    var sampledAt: Date
}

struct ChannelUtilizationRadio: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var eeroID: String?
    var eeroName: String?
    var band: String?
    var controlChannel: Int?
    var centerChannel: Int?
    var channelBandwidth: String?
    var frequencyMHz: Int?
    var averageUtilization: Int?
    var maxUtilization: Int?
    var p99Utilization: Int?
    var timeSeries: [ChannelUtilizationSample]
}

struct ChannelUtilizationSample: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var timestamp: Date
    var busyPercent: Int?
    var noisePercent: Int?
    var rxTxPercent: Int?
    var rxOtherPercent: Int?
}

struct ThreadNetworkDetails: Codable, Equatable, Sendable {
    var name: String?
    var channel: Int?
    var panID: String?
    var xpanID: String?
    var commissioningCredential: String?
    var activeOperationalDataset: String?
}

struct BurstReporterSummary: Codable, Equatable, Sendable {
    var status: String?
}
