import Charts
import SwiftUI

private struct ThroughputPoint: Identifiable {
  let id = UUID()
  let timestamp: Date
  let downloadMbps: Double
  let uploadMbps: Double
  let sourceLabel: String
  let contextLabel: String
}

private enum ThroughputSeries: String, CaseIterable {
  case download = "Download"
  case upload = "Upload"

  var color: Color {
    switch self {
    case .download:
      return .green
    case .upload:
      return .blue
    }
  }
}

private struct BusiestStackedSegment: Identifiable {
  let id: String
  let timestamp: Date
  let deviceName: String
  let timelineOrder: Int
  let series: ThroughputSeries
  let yStart: Double
  let yEnd: Double
  let bytes: Int
}

private struct ThroughputTimelineGraphView: View {
  let samples: [ThroughputPoint]

  @State private var selectedPoint: ThroughputPoint?
  @State private var isHovering = false

  private var orderedSamples: [ThroughputPoint] {
    samples.sorted { $0.timestamp < $1.timestamp }
  }

  private var xDomain: ClosedRange<Date> {
    guard let first = orderedSamples.first?.timestamp,
      let last = orderedSamples.last?.timestamp
    else {
      let now = Date()
      return now...now.addingTimeInterval(300)
    }

    if first == last {
      return first...first.addingTimeInterval(300)
    }

    return first...last
  }

  private var magnitude: Double {
    let maxDownload = orderedSamples.map(\.downloadMbps).max() ?? 0
    let maxUpload = orderedSamples.map(\.uploadMbps).max() ?? 0
    let highest = max(maxDownload, maxUpload)
    return max(1, highest * 1.15)
  }

  var body: some View {
    if orderedSamples.count < 2 {
      Label("Need at least two samples for a traffic timeline.", systemImage: "chart.xyaxis.line")
        .font(.callout)
        .foregroundStyle(.secondary)
    } else {
      VStack(alignment: .leading, spacing: 4) {
        Chart {
          ForEach(orderedSamples) { sample in
            BarMark(
              x: .value("Time", sample.timestamp),
              yStart: .value("Start", 0),
              yEnd: .value("Download", sample.downloadMbps)
            )
            .foregroundStyle(ThroughputSeries.download.color.opacity(0.62))
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))

            BarMark(
              x: .value("Time", sample.timestamp),
              yStart: .value("Start", -sample.uploadMbps),
              yEnd: .value("Upload", 0)
            )
            .foregroundStyle(ThroughputSeries.upload.color.opacity(0.62))
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
          }
        }
        .chartYScale(domain: -magnitude...magnitude)
        .chartXScale(domain: xDomain)
        .chartXAxisLabel("Time", alignment: .center)
        .chartXAxis {
          AxisMarks(values: .automatic(desiredCount: 6)) { value in
            AxisTick()
            AxisValueLabel {
              if let date: Date = value.as(Date.self) {
                Text(date, format: .dateTime.hour().minute())
              }
            }
          }
        }
        .chartYAxis {
          AxisMarks(position: .leading) { value in
            AxisGridLine()
              .foregroundStyle(.secondary.opacity(0.2))
            AxisTick()
            AxisValueLabel {
              if let y = value.as(Double.self) {
                Text(formatMbpsText(y))
              }
            }
          }
        }
        .chartLegend(.hidden)
        .frame(height: 180)
        .chartOverlay { proxy in
          GeometryReader { geometry in
            let plotFrame = geometry[proxy.plotAreaFrame]
            Rectangle()
              .fill(.clear)
              .contentShape(Rectangle())
              .onContinuousHover { phase in
                switch phase {
                case .active(let hoverLocation):
                  isHovering = true
                  let adjustedX = hoverLocation.x - plotFrame.minX
                  selectedPoint = sample(closestToX: adjustedX, using: proxy, plotFrame: plotFrame)
                  if selectedPoint == nil {
                    isHovering = false
                  }
                case .ended:
                  isHovering = false
                  selectedPoint = nil
                @unknown default:
                  isHovering = false
                  selectedPoint = nil
                }
              }
          }
        }
        .overlay(alignment: .topLeading) {
          if isHovering, let selectedPoint {
            hoverCard(for: selectedPoint)
              .padding(.horizontal, 8)
              .padding(.vertical, 6)
              .liquidGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
              .padding(.top, 4)
          }
        }

        if let first = orderedSamples.first?.timestamp,
          let last = orderedSamples.last?.timestamp
        {
          HStack {
            Text(first, format: .dateTime.hour().minute())
            Spacer()
            Text(last, format: .dateTime.hour().minute())
          }
          .font(.caption2)
          .foregroundStyle(.secondary)
        }

        if let point = selectedPoint {
          HStack {
            Label("↓ \(formatMbps(point.downloadMbps))", systemImage: "arrow.down.circle")
              .foregroundStyle(.green)
              .font(.caption.weight(.semibold))
            Label("↑ \(formatMbps(point.uploadMbps))", systemImage: "arrow.up.circle")
              .foregroundStyle(.blue)
              .font(.caption.weight(.semibold))
          }
        } else if let sample = orderedSamples.last {
          HStack {
            Label("↓ \(formatMbps(sample.downloadMbps))", systemImage: "arrow.down.circle")
              .foregroundStyle(.green)
              .font(.caption.weight(.semibold))
            Label("↑ \(formatMbps(sample.uploadMbps))", systemImage: "arrow.up.circle")
              .foregroundStyle(.blue)
              .font(.caption.weight(.semibold))
          }
        }
      }
    }
  }

  private func hoverCard(for sample: ThroughputPoint) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(sample.timestamp, format: .dateTime.day().month().year().hour().minute().second())
        .font(.caption2)
        .foregroundStyle(.secondary)
      Text("Download: \(formatMbps(sample.downloadMbps))")
        .font(.caption.weight(.semibold))
      Text("Upload: \(formatMbps(sample.uploadMbps))")
        .font(.caption.weight(.semibold))
    }
  }

  private func formatMbpsText(_ value: Double) -> String {
    if value == 0 {
      return "0"
    }
    if abs(value) >= 1000 {
      return String(format: value > 0 ? "%.1f Gbps" : "%.1f Gbps", abs(value) / 1000)
    }
    return String(format: "%.1f Mbps", abs(value))
  }

  private func formatMbps(_ value: Double) -> String {
    if value >= 100 {
      return String(format: "%.0f Mbps", value)
    }
    if value >= 10 {
      return String(format: "%.1f Mbps", value)
    }
    return String(format: "%.2f Mbps", value)
  }

  private func sample(closestToX adjustedX: CGFloat, plotFrame: CGRect) -> ThroughputPoint? {
    guard !orderedSamples.isEmpty else {
      return nil
    }

    let clampedX = min(max(adjustedX, 0), plotFrame.size.width)
    guard plotFrame.size.width > 0 else {
      return orderedSamples.last
    }

    return sample(closestToX: clampedX, using: nil, plotFrame: plotFrame)
  }

  private func sample(closestToX adjustedX: CGFloat, using proxy: ChartProxy?, plotFrame: CGRect)
    -> ThroughputPoint?
  {
    guard !orderedSamples.isEmpty else {
      return nil
    }

    if let proxy, let timestamp: Date = proxy.value(atX: adjustedX, as: Date.self) {
      return orderedSamples.min {
        abs($0.timestamp.timeIntervalSince(timestamp))
          < abs($1.timestamp.timeIntervalSince(timestamp))
      }
    }

    let clampedX = min(max(adjustedX, 0), plotFrame.size.width)
    guard plotFrame.size.width > 0 else { return orderedSamples.last }

    let fallbackProgress = clampedX / plotFrame.size.width
    let maxIndex = orderedSamples.count - 1
    let candidateIndex = Int(round(fallbackProgress * Double(maxIndex)))
    let fallbackIndex = min(max(candidateIndex, 0), maxIndex)

    return orderedSamples[fallbackIndex]
  }
}

private struct BusiestDevicesTimelineChartView: View {
  let timelines: [DeviceUsageTimeline]

  @State private var selectedSegment: BusiestStackedSegment?
  @State private var isHovering = false

  private var segments: [BusiestStackedSegment] {
    busiestSegments(from: timelines)
  }

  private var domain: ClosedRange<Date> {
    let now = Date()
    guard let first = segments.map(\.timestamp).min(),
      let last = segments.map(\.timestamp).max()
    else {
      return now.addingTimeInterval(-86_400)...now
    }
    if abs(last.timeIntervalSince(first)) < 1 {
      return first.addingTimeInterval(-1800)...last.addingTimeInterval(1800)
    }
    return first...last
  }

  private var yDomain: ClosedRange<Double> {
    var maxDownload: Double = 0
    var maxUpload: Double = 0
    for segment in segments {
      if segment.series == .download {
        maxDownload = max(maxDownload, segment.yEnd)
      } else {
        maxUpload = max(maxUpload, abs(segment.yEnd))
      }
    }
    let positive = max(1, maxDownload * 1.15)
    let negative = max(1, maxUpload * 1.15)
    return -negative...positive
  }

  private var segmentColor: (BusiestStackedSegment) -> Color {
    let palette: [Color] = [
      .blue,
      .orange,
      .green,
      .mint,
      .pink,
      .purple,
      .teal,
      .indigo,
      .brown,
    ]

    return { segment in
      let base = palette[abs(segment.timelineOrder) % palette.count]
      return segment.series == .download ? base.opacity(0.65) : base.opacity(0.35)
    }
  }

  var body: some View {
    if segments.isEmpty {
      Label("No busiest device timeline data yet.", systemImage: "chart.bar.doc.horizontal")
        .font(.callout)
        .foregroundStyle(.secondary)
    } else {
      VStack(alignment: .leading, spacing: 6) {
        Chart {
          ForEach(segments) { segment in
            BarMark(
              x: .value("Time", segment.timestamp),
              yStart: .value("Start", segment.yStart),
              yEnd: .value("End", segment.yEnd)
            )
            .foregroundStyle(segmentColor(segment))
            .cornerRadius(2)
          }
        }
        .chartYScale(domain: yDomain)
        .chartXScale(domain: domain)
        .chartXAxisLabel("Time", alignment: .center)
        .chartXAxis {
          AxisMarks(values: .automatic(desiredCount: 6)) { value in
            AxisTick()
            AxisValueLabel {
              if let date: Date = value.as(Date.self) {
                Text(date, format: .dateTime.hour().minute())
              }
            }
          }
        }
        .chartYAxis {
          AxisMarks(position: .leading) { value in
            AxisGridLine()
              .foregroundStyle(.secondary.opacity(0.2))
            AxisTick()
            AxisValueLabel {
              if let y = value.as(Double.self) {
                Text(formatBytes(y))
              }
            }
          }
        }
        .chartLegend(.hidden)
        .frame(height: 200)
        .chartOverlay { proxy in
          GeometryReader { geometry in
            let plotFrame = geometry[proxy.plotAreaFrame]
            Rectangle()
              .fill(.clear)
              .contentShape(Rectangle())
              .onContinuousHover { phase in
                switch phase {
                case .active(let hoverLocation):
                  isHovering = true
                  let adjustedX = hoverLocation.x - plotFrame.origin.x
                  let adjustedY = hoverLocation.y - plotFrame.origin.y
                  selectedSegment = segment(
                    closestToX: adjustedX,
                    using: proxy,
                    yValue: proxy.value(atY: adjustedY, as: Double.self),
                    plotFrame: plotFrame
                  )
                case .ended:
                  isHovering = false
                  selectedSegment = nil
                @unknown default:
                  isHovering = false
                  selectedSegment = nil
                }
              }
          }
        }
        .overlay(alignment: .topTrailing) {
          if isHovering, let segment = selectedSegment {
            VStack(alignment: .leading, spacing: 2) {
              Text(
                segment.timestamp, format: .dateTime.day().month().year().hour().minute().second()
              )
              .font(.caption2)
              .foregroundStyle(.secondary)
              Text("\(segment.deviceName)")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
              Text("\(segment.series.rawValue): \(formattedByteCount(segment.bytes))")
                .font(.caption2)
            }
            .padding(8)
            .liquidGlass(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(8)
          }
        }

        Text("Stacked busiest-device timeline")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func formatBytes(_ value: Double) -> String {
    if value == 0 {
      return "0 B"
    }
    let formatter = ByteCountFormatter()
    formatter.countStyle = .binary
    return formatter.string(fromByteCount: Int64(abs(value)))
  }

  private func formattedByteCount(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(max(0, bytes)), countStyle: .binary)
  }

  private func segmentContains(_ segment: BusiestStackedSegment, yValue: Double) -> Bool {
    if segment.yStart <= segment.yEnd {
      return yValue >= segment.yStart && yValue <= segment.yEnd
    }
    return yValue >= segment.yEnd && yValue <= segment.yStart
  }

  private func midpoint(of segment: BusiestStackedSegment) -> Double {
    (segment.yStart + segment.yEnd) / 2
  }

  private var timestamps: [Date] {
    Dictionary(grouping: segments, by: \.timestamp)
      .keys
      .sorted()
  }

  private func segment(
    closestToX adjustedX: CGFloat,
    using proxy: ChartProxy,
    yValue: Double?,
    plotFrame: CGRect
  ) -> BusiestStackedSegment? {
    guard !segments.isEmpty else {
      return nil
    }

    let clampedX = min(max(adjustedX, 0), plotFrame.size.width)
    guard plotFrame.size.width > 0 else {
      return segments.last
    }

    guard let cursorDate: Date = proxy.value(atX: clampedX, as: Date.self),
      !timestamps.isEmpty
    else {
      return nil
    }

    guard let firstSample = nearestTimestamp(to: cursorDate) else {
      return nil
    }

    let sameTimestamp = segments.filter { $0.timestamp == firstSample }
    guard !sameTimestamp.isEmpty else {
      return nil
    }

    guard let yValue else {
      return
        sameTimestamp
        .max { abs(midpoint(of: $0) - 0) < abs(midpoint(of: $1) - 0) } ?? sameTimestamp.first
    }

    if let hit = sameTimestamp.first(where: { segment in
      segmentContains(segment, yValue: yValue)
    }) {
      return hit
    }

    return sameTimestamp.max(by: {
      abs(midpoint(of: $0) - yValue) < abs(midpoint(of: $1) - yValue)
    }) ?? sameTimestamp.first
  }

  private func nearestTimestamp(to cursorDate: Date) -> Date? {
    guard !timestamps.isEmpty else {
      return nil
    }
    return timestamps.min(by: {
      abs($0.timeIntervalSince(cursorDate)) < abs($1.timeIntervalSince(cursorDate))
    })
  }

  private func busiestSegments(from timelines: [DeviceUsageTimeline]) -> [BusiestStackedSegment] {
    let sortedTimelines =
      timelines
      .enumerated()
      .filter { !$0.element.samples.isEmpty }

    if sortedTimelines.isEmpty {
      return []
    }

    let normalizedSamples = sortedTimelines.map { index, timeline in
      var sampleBySecond: [Int64: DeviceUsageTimelineSample] = [:]
      for sample in timeline.samples {
        let key = Int64(sample.timestamp.timeIntervalSince1970.rounded())
        sampleBySecond[key] = sample
      }

      return (index: index, timeline: timeline, sampleBySecond: sampleBySecond)
    }

    let allTimestamps = Set(normalizedSamples.flatMap { $0.sampleBySecond.keys }).sorted()
    var output: [BusiestStackedSegment] = []

    for timestampKey in allTimestamps {
      let timestamp = Date(timeIntervalSince1970: TimeInterval(timestampKey))
      var downloadRunning = 0.0
      var uploadRunning = 0.0

      for item in normalizedSamples {
        guard let sample = item.sampleBySecond[timestampKey] else {
          continue
        }

        let download = Double(max(0, sample.downloadBytes))
        if download > 0 {
          let start = downloadRunning
          let end = downloadRunning + download
          output.append(
            BusiestStackedSegment(
              id: "segment-\(timestampKey)-\(item.index)-download",
              timestamp: timestamp,
              deviceName: item.timeline.name,
              timelineOrder: item.index,
              series: .download,
              yStart: start,
              yEnd: end,
              bytes: Int(download)
            )
          )
          downloadRunning = end
        }

        let upload = Double(max(0, sample.uploadBytes))
        if upload > 0 {
          let start = uploadRunning
          let end = uploadRunning - upload
          output.append(
            BusiestStackedSegment(
              id: "segment-\(timestampKey)-\(item.index)-upload",
              timestamp: timestamp,
              deviceName: item.timeline.name,
              timelineOrder: item.index,
              series: .upload,
              yStart: start,
              yEnd: end,
              bytes: Int(upload)
            )
          )
          uploadRunning = end
        }
      }
    }

    return output.sorted { left, right in
      if left.timestamp != right.timestamp {
        return left.timestamp < right.timestamp
      }
      if left.timelineOrder != right.timelineOrder {
        return left.timelineOrder < right.timelineOrder
      }
      return left.series == .download && right.series == .upload
    }
  }
}

struct DashboardView: View {
  @EnvironmentObject private var appState: AppState
  @State private var throughputHistory: [ThroughputPoint] = []

  private let cardColumns = [GridItem(.adaptive(minimum: 420), spacing: 12, alignment: .top)]
  private let historyRetentionSeconds: TimeInterval = 900
  private let maxHistorySamples: Int = 300

  private var selectedNetwork: EeroNetwork? {
    appState.selectedNetwork
  }

  private var latestThroughput: ThroughputPoint? {
    throughputHistory.last
  }

  private var pendingQueueCount: Int {
    appState.queuedActions.filter { $0.status == .pending }.count
  }

  private var failedQueueCount: Int {
    appState.queuedActions.filter { $0.status == .failed }.count
  }

  private var queueSummary: String {
    if pendingQueueCount == 0, failedQueueCount == 0 {
      return "No queued actions"
    }
    return "\(pendingQueueCount) pending · \(failedQueueCount) failed"
  }

  var body: some View {
    ScrollView {
      if let network = selectedNetwork {
        VStack(alignment: .leading, spacing: 12) {
          networkPulseCard(network: network)

          LazyVGrid(columns: cardColumns, alignment: .leading, spacing: 12) {
            throughputTimelineCard(network: network)
            busiestDevicesCard(network: network)
            meshAndRadiosCard(network: network)
            routerPortsCard(network: network)
            controlCenterCard(network: network)
            operationsCard
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
      } else {
        SectionCard(title: "Dashboard") {
          Text("No network selected")
            .foregroundStyle(.secondary)
        }
      }
    }
    .onAppear {
      rebuildHistoryFromCurrentState(reset: true)
    }
    .onChange(of: appState.selectedNetworkID) { _ in
      rebuildHistoryFromCurrentState(reset: true)
    }
    .onChange(of: selectedNetwork?.lastUpdated) { _ in
      rebuildHistoryFromCurrentState(reset: false)
    }
  }

  private func networkPulseCard(network: EeroNetwork) -> some View {
    SectionCard(title: "Network Pulse") {
      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 170), spacing: 8, alignment: .top)], spacing: 8
      ) {
        pulseTile(
          icon: "dot.radiowaves.left.and.right",
          title: "Status",
          value: network.status ?? "Unknown",
          detail: network.displayName,
          tone: toneForText(network.status)
        )

        pulseTile(
          icon: "person.3.fill",
          title: "Clients Online",
          value: "\(network.connectedClientsCount)",
          detail: "Guest: \(network.connectedGuestClientsCount)",
          tone: .success
        )

        pulseTile(
          icon: "wifi",
          title: "Guest LAN",
          value: network.guestNetworkEnabled ? "Enabled" : "Disabled",
          detail: network.guestNetworkName ?? "Guest network",
          tone: network.guestNetworkEnabled ? .accent : .neutral
        )

        pulseTile(
          icon: "point.3.connected.trianglepath.dotted",
          title: "Mesh",
          value:
            "\(network.mesh?.onlineEeroCount ?? 0)/\(network.mesh?.eeroCount ?? max(1, network.devices.count)) online",
          detail: network.mesh?.gatewayName ?? "Gateway unknown",
          tone: (network.mesh?.onlineEeroCount ?? 0) > 0 ? .success : .warning
        )

        pulseTile(
          icon: "gauge.with.dots.needle.67percent",
          title: "Last Speed Test",
          value: speedPairText(network),
          detail: network.speed.measuredAt ?? "No sample",
          tone: .accent
        )
      }
    }
  }

  private func throughputTimelineCard(network: EeroNetwork) -> some View {
    SectionCard(title: "Traffic Timeline") {
      if throughputHistory.count > 1 {
        ThroughputTimelineGraphView(samples: throughputHistory)
      } else {
        Label("No eero realtime telemetry in this refresh.", systemImage: "waveform.path.ecg")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      HStack(spacing: 8) {
        metricPill(
          icon: "arrow.down", label: "Download",
          value: latestThroughput.map { formatMbps($0.downloadMbps) } ?? "--", tone: .success)
        metricPill(
          icon: "arrow.up", label: "Upload",
          value: latestThroughput.map { formatMbps($0.uploadMbps) } ?? "--", tone: .accent)
      }
    }
  }

  private func busiestDevicesCard(network: EeroNetwork) -> some View {
    SectionCard(title: "Busiest Devices") {
      let timelines = (network.activity?.busiestDeviceTimelines ?? []).filter {
        !$0.samples.isEmpty
      }
      let hasTimelines = !timelines.isEmpty

      if hasTimelines {
        BusiestDevicesTimelineChartView(timelines: timelines)
      }
      if !hasTimelines {
        Text("No per-device usage timeline available for this network.")
          .foregroundStyle(.secondary)
      }
    }
  }

  private func meshAndRadiosCard(network: EeroNetwork) -> some View {
    SectionCard(title: "Mesh and Radio Analytics") {
      if let mesh = network.mesh {
        infoRow(
          icon: "point.3.connected.trianglepath.dotted", label: "eero Nodes",
          value: "\(mesh.onlineEeroCount)/\(mesh.eeroCount) online", tone: .neutral)
        infoRow(
          icon: "house.fill", label: "Gateway", value: mesh.gatewayName ?? "Unknown", tone: .neutral
        )
        infoRow(
          icon: "arrow.left.arrow.right", label: "Backhaul",
          value: "Wired \(mesh.wiredBackhaulCount) · Wireless \(mesh.wirelessBackhaulCount)",
          tone: .neutral)
        infoRow(
          icon: "dot.scope", label: "Mesh Quality",
          value: mesh.averageMeshQualityBars.map { String(format: "%.1f / 4", $0) } ?? "Unknown",
          tone: .accent)
      }

      if let proxied = network.proxiedNodes {
        infoRow(
          icon: "wifi.exclamationmark", label: "Proxied Nodes",
          value: "\(proxied.onlineDevices)/\(proxied.totalDevices) online",
          tone: proxied.offlineDevices > 0 ? .warning : .success)
      }

      if let radios = network.channelUtilization?.radios, !radios.isEmpty {
        if let primaryRadio = radios.first, !primaryRadio.timeSeries.isEmpty {
          Chart {
            ForEach(primaryRadio.timeSeries) { sample in
              LineMark(
                x: .value("Time", sample.timestamp),
                y: .value("Busy", sample.busyPercent ?? 0)
              )
              .foregroundStyle(.orange)
              .interpolationMethod(.catmullRom)
            }
          }
          .chartYScale(domain: 0...100)
          .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
              AxisTick()
              AxisValueLabel(format: .dateTime.hour().minute())
            }
          }
          .frame(height: 120)

          Text("Focused radio: \(radioLabel(primaryRadio))")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Divider()

        ForEach(radios.prefix(6)) { radio in
          infoRow(
            icon: "wave.3.right",
            label: radioLabel(radio),
            value:
              "Avg \(radio.averageUtilization.map { "\($0)%" } ?? "--") · Max \(radio.maxUtilization.map { "\($0)%" } ?? "--")",
            tone: (radio.averageUtilization ?? 0) >= 70 ? .warning : .neutral
          )
        }
      } else if let congestion = network.wirelessCongestion {
        infoRow(
          icon: "wifi", label: "Wireless Clients", value: "\(congestion.wirelessClientCount)",
          tone: .neutral)
        infoRow(
          icon: "antenna.radiowaves.left.and.right", label: "Poor Signal",
          value: "\(congestion.poorSignalClientCount)",
          tone: congestion.poorSignalClientCount > 0 ? .warning : .success)
        ForEach(congestion.congestedChannels.prefix(6)) { channel in
          infoRow(
            icon: "dot.radiowaves.left.and.right",
            label: "CH \(channel.channel.map(String.init) ?? "?") · \(channel.band ?? "Unknown")",
            value: "\(channel.clientCount) weighted load",
            tone: .neutral
          )
        }
      } else {
        Text("No radio analytics available.")
          .foregroundStyle(.secondary)
      }
    }
  }

  private func routerPortsCard(network: EeroNetwork) -> some View {
    SectionCard(title: "Router and Port Stats") {
      if network.devices.isEmpty {
        Text("No eero node details available for this network.")
          .foregroundStyle(.secondary)
      } else {
        ForEach(network.devices) { device in
          VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
              Image(systemName: device.isGateway ? "house.fill" : "router")
                .foregroundStyle(device.isGateway ? Color.blue : Color.secondary)
              Text(device.name)
                .font(.callout.weight(.semibold))
              Spacer()
              Text(device.status ?? "Unknown")
                .font(.caption)
                .foregroundStyle(toneForText(device.status).foregroundColor)
            }

            infoRow(
              icon: "person.2.fill", label: "Connected Clients",
              value:
                "Total \(device.connectedClientCount ?? 0) · Wired \(device.connectedWiredClientCount ?? 0) · Wireless \(device.connectedWirelessClientCount ?? 0)",
              tone: .neutral)
            infoRow(
              icon: "arrow.left.arrow.right", label: "Backhaul",
              value: device.wiredBackhaul == true
                ? "Wired" : (device.wiredBackhaul == false ? "Wireless" : "Unknown"),
              tone: device.wiredBackhaul == true ? .success : .neutral)
            infoRow(
              icon: "wifi", label: "Radio Bands",
              value: device.wifiBands.isEmpty
                ? "Unknown" : device.wifiBands.joined(separator: ", "), tone: .neutral)

            if !device.ethernetStatuses.isEmpty {
              ForEach(device.ethernetStatuses.prefix(5)) { status in
                infoRow(
                  icon: (status.hasCarrier == true) ? "cable.connector" : "cable.connector.slash",
                  label: status.portName
                    ?? "Port \(status.interfaceNumber.map(String.init) ?? "?")",
                  value:
                    "\(status.speedTag ?? "speed n/a") · \(status.peerCountDescription(allPortStatuses: device.ethernetStatuses))",
                  tone: status.hasCarrier == true ? .success : .neutral
                )
              }
            } else if !device.portDetails.isEmpty {
              ForEach(device.portDetails.prefix(5)) { detail in
                infoRow(
                  icon: "cable.connector",
                  label: detail.portName ?? "Port \(detail.position.map(String.init) ?? "?")",
                  value: detail.ethernetAddress ?? "No ethernet address",
                  tone: .neutral
                )
              }
            }

            if device.id != network.devices.last?.id {
              Divider()
            }
          }
        }
      }
    }
  }

  private func controlCenterCard(network: EeroNetwork) -> some View {
    SectionCard(title: "Control Center") {
      controlToggleRow(
        icon: "wifi",
        title: "Guest Network",
        subtitle: network.guestNetworkName ?? "Guest LAN",
        isOn: Binding(
          get: { network.guestNetworkEnabled },
          set: { appState.setGuestNetwork(network: network, enabled: $0) }
        ),
        tone: network.guestNetworkEnabled ? .accent : .neutral
      )

      if let adBlock = network.features.adBlock {
        controlToggleRow(
          icon: "shield.lefthalf.filled",
          title: "Ad Blocking",
          subtitle: "DNS policy",
          isOn: Binding(
            get: { adBlock },
            set: { appState.setNetworkFeature(network: network, key: "ad_block", enabled: $0) }
          ),
          tone: adBlock ? .success : .neutral
        )
      }

      if let malware = network.features.blockMalware {
        controlToggleRow(
          icon: "ant.fill",
          title: "Malware Blocking",
          subtitle: "DNS policy",
          isOn: Binding(
            get: { malware },
            set: { appState.setNetworkFeature(network: network, key: "block_malware", enabled: $0) }
          ),
          tone: malware ? .success : .neutral
        )
      }

      if let upnp = network.features.upnp {
        controlToggleRow(
          icon: "link.badge.plus",
          title: "UPnP",
          subtitle: "Port mapping",
          isOn: Binding(
            get: { upnp },
            set: { appState.setNetworkFeature(network: network, key: "upnp", enabled: $0) }
          ),
          tone: upnp ? .accent : .neutral
        )
      }
    }
  }

  private var operationsCard: some View {
    SectionCard(title: "Operations") {
      if let freshness = appState.cachedFreshness {
        infoRow(
          icon: "clock.fill",
          label: "Data Age",
          value: formatAge(freshness.age),
          tone: freshness.age < 30 ? .success : .warning
        )
      } else {
        infoRow(icon: "clock.fill", label: "Data Age", value: "No cache", tone: .warning)
      }

      infoRow(
        icon: "clock.arrow.circlepath",
        label: "Queue",
        value: queueSummary,
        tone: failedQueueCount > 0 ? .danger : (pendingQueueCount > 0 ? .warning : .success)
      )

      HStack(spacing: 8) {
        Button("Replay Queue") {
          appState.replayQueuedActions()
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .liquidGlass(in: Capsule(), tint: .blue.opacity(0.22), interactive: true)

        Button("Refresh") {
          appState.refreshNow()
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .liquidGlass(
          in: Capsule(), tint: AppTone.neutral.backgroundColor.opacity(0.22), interactive: true)
      }
    }
  }

  private func pulseTile(icon: String, title: String, value: String, detail: String, tone: AppTone)
    -> some View
  {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 5) {
        Image(systemName: icon)
          .font(.caption.weight(.semibold))
          .foregroundStyle(tone.foregroundColor)

        Text(title)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)

        Spacer(minLength: 4)

        Circle()
          .fill(tone.foregroundColor)
          .frame(width: 7, height: 7)
          .opacity(tone == .neutral ? 0.5 : 0.95)
      }

      Text(value)
        .font(.title3.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.78)
        .monospacedDigit()

      Text(detail)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .liquidGlass(
      in: RoundedRectangle(cornerRadius: 10, style: .continuous),
      tint: tone.backgroundColor.opacity(0.6))
  }

  private func metricPill(icon: String, label: String, value: String, tone: AppTone) -> some View {
    HStack(spacing: 6) {
      Image(systemName: icon)
        .font(.caption2)
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.caption.weight(.semibold))
        .monospacedDigit()
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .foregroundStyle(tone.foregroundColor)
    .liquidGlass(in: Capsule(), tint: tone.backgroundColor.opacity(0.7))
  }

  private func controlToggleRow(
    icon: String, title: String, subtitle: String, isOn: Binding<Bool>, tone: AppTone
  ) -> some View {
    HStack(spacing: 10) {
      ZStack {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(tone.backgroundColor.opacity(0.6))
          .frame(width: 28, height: 28)
        Image(systemName: icon)
          .font(.caption.weight(.semibold))
          .foregroundStyle(tone.foregroundColor)
      }

      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.callout.weight(.semibold))
        Text(subtitle)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 8)

      Toggle("", isOn: isOn)
        .labelsHidden()
        .toggleStyle(.switch)
    }
    .padding(.vertical, 4)
  }

  private func infoRow(icon: String, label: String, value: String, tone: AppTone) -> some View {
    HStack(spacing: 8) {
      Image(systemName: icon)
        .font(.caption.weight(.semibold))
        .foregroundStyle(tone.foregroundColor)
        .frame(width: 16)

      Text(label)
        .foregroundStyle(.secondary)

      Spacer(minLength: 8)

      Text(value)
        .multilineTextAlignment(.trailing)
        .foregroundStyle(tone.foregroundColor)
    }
    .font(.callout)
  }

  private func rebuildHistoryFromCurrentState(reset: Bool) {
    if reset {
      throughputHistory.removeAll()
    }

    if let realtime = selectedNetwork?.realtime {
      appendRealtimeThroughputSample(realtime, network: selectedNetwork)
      return
    }
  }

  private func appendRealtimeThroughputSample(
    _ realtime: NetworkRealtimeSummary, network: EeroNetwork?
  ) {
    let context = network.map { "\($0.connectedClientsCount) online clients" } ?? "Network sample"
    let point = ThroughputPoint(
      timestamp: realtime.sampledAt,
      downloadMbps: max(0, realtime.downloadMbps),
      uploadMbps: max(0, realtime.uploadMbps),
      sourceLabel: "Source: \(realtime.sourceLabel)",
      contextLabel: context
    )
    appendPoint(point)
  }

  private func appendPoint(_ point: ThroughputPoint) {
    if let last = throughputHistory.last,
      abs(point.timestamp.timeIntervalSince(last.timestamp)) < 0.9
    {
      throughputHistory[throughputHistory.count - 1] = point
    } else {
      throughputHistory.append(point)
    }

    let cutoff = Date().addingTimeInterval(-historyRetentionSeconds)
    throughputHistory.removeAll { $0.timestamp < cutoff }

    if throughputHistory.count > maxHistorySamples {
      throughputHistory.removeFirst(throughputHistory.count - maxHistorySamples)
    }
  }

  private func radioLabel(_ radio: ChannelUtilizationRadio) -> String {
    let node = radio.eeroName ?? radio.eeroID ?? "eero"
    let band = radio.band ?? "band"
    let channel = radio.controlChannel.map(String.init) ?? "?"
    return "\(node) · \(band) · CH \(channel)"
  }

  private func realtimePairText(_ network: EeroNetwork) -> String {
    if let realtime = network.realtime {
      return "↓\(formatMbps(realtime.downloadMbps)) ↑\(formatMbps(realtime.uploadMbps))"
    }
    return "Unavailable"
  }

  private func realtimeSourceText(_ network: EeroNetwork) -> String {
    if let realtime = network.realtime {
      return realtime.sourceLabel
    }
    return "No realtime source"
  }

  private func speedPairText(_ network: EeroNetwork) -> String {
    "\(formatSpeed(network.speed.measuredDownValue))/\(formatSpeed(network.speed.measuredUpValue))"
  }

  private func formatAge(_ seconds: TimeInterval) -> String {
    if seconds < 60 {
      return "\(Int(seconds))s"
    }
    if seconds < 3_600 {
      return "\(Int(seconds / 60))m \(Int(seconds) % 60)s"
    }
    return "\(Int(seconds / 3_600))h \(Int(seconds.truncatingRemainder(dividingBy: 3_600) / 60))m"
  }

  private func formattedByteCount(_ value: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(max(0, value)), countStyle: .binary)
  }

  private func formatSpeed(_ value: Double?) -> String {
    guard let value else { return "?" }
    return String(format: "%.1f", value)
  }

  private func formatMbps(_ value: Double) -> String {
    if value >= 100 {
      return String(format: "%.0f Mbps", value)
    }
    if value >= 10 {
      return String(format: "%.1f Mbps", value)
    }
    return String(format: "%.2f Mbps", value)
  }

  private func toneForLanStatus() -> AppTone {
    switch appState.offlineSnapshot.localHealthLabel {
    case "LAN OK":
      return .success
    case "LAN Degraded":
      return .warning
    case "LAN Down":
      return .danger
    default:
      return .neutral
    }
  }

  private func toneForCloudStatus() -> AppTone {
    switch appState.cloudState {
    case .reachable:
      return .success
    case .degraded:
      return .warning
    case .unreachable:
      return .danger
    case .unknown:
      return .neutral
    }
  }

  private func toneForText(_ value: String?) -> AppTone {
    guard let value = value?.lowercased() else { return .neutral }
    if value.contains("connect") || value.contains("ok") || value.contains("up")
      || value.contains("enabled") || value.contains("available")
    {
      return .success
    }
    if value.contains("degraded") || value.contains("warn") {
      return .warning
    }
    if value.contains("down") || value.contains("fail") || value.contains("error")
      || value.contains("disable")
    {
      return .danger
    }
    return .neutral
  }
}
