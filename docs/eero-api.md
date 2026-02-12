# EeroControl API Usage (Current App Behavior)

This document describes the **network-facing** and **local probe** interfaces used by the macOS SwiftUI app in this repo (`EeroControl`), based on the current code in `Sources/EeroControl`.

The eero APIs used here are **undocumented / unofficial**. Expect schema drift and prefer server-provided `resources` URLs when available.

## Discovered API Calls (Reference App)

This file (`docs/eero-api.md`) documents **what EeroControl uses today**. It does **not** attempt to enumerate every endpoint used by the official Android app.

To support coverage checks, a separate catalog is generated from a static scan of the Android app’s Retrofit interface annotations:

- `docs/eero-api-discovered-endpoints.tsv`
- `docs/eero-api-discovered-path-strings.txt` (broader string scan; noisier)

Notes about that catalog:

- It includes **all unique** `@GET/@POST/@PUT/@DELETE/@PATCH` `value = "..."` strings found in `third-party/eero-app/out/smali*` (currently 231 entries).
- It will **not** include endpoints passed via Retrofit `@Url` parameters, nor non-HTTP local APIs (e.g., the Android app’s local gRPC “Nimble” services).
- The `*-path-strings.txt` file additionally captures many dynamically-built paths (string constants), but it can still miss paths that are fully constructed at runtime.

## Cloud API

### Base URL, Auth, and Envelope

- Base URL: `https://api-user.e2ro.com`
  - The app passes either absolute URLs (from API `resources`) or relative paths (e.g. `/2.2/account`).
- Auth mechanism: **Cookie header** (not Bearer tokens)
  - `Cookie: s=<user_token>`
  - Implemented in `Sources/EeroControl/Services/EeroAPIClient.swift` `call(...)`.
- Response envelope:
  - Many endpoints return `{ "data": <payload>, "meta": ... }`
  - The client unwraps `data` when present; otherwise it uses the raw JSON.

### Session / Login

Endpoints (all relative to base URL):

- `POST /2.2/login`
  - Body: `{ "login": "<phone-or-email>" }`
  - Response payload: expects `user_token`
- `POST /2.2/login/verify`
  - Body: `{ "code": "<verification-code>" }`
  - Requires auth cookie from `/2.2/login`
  - Response payload: used for `name` and `log_id` (best-effort)
- `POST /2.2/login/refresh`
  - Requires auth cookie
  - Response payload: expects a new `user_token`
  - The client automatically calls this on `401` for other requests (once), then retries the original request.

### Account + Network Inventory Fetch

The app refresh flow is effectively:

1. `GET /2.2/account`
2. For each network reference in `account.networks.data[]`:
   - `GET <network.url>` (absolute URL returned by API)
   - Read `network.resources` to discover additional endpoints; fall back to hard-coded paths when missing.

Network resources fetched (when present; otherwise fallback paths are used):

- Thread network details:
  - Resource key: `thread`
  - Fallback: `GET /2.2/networks/{networkId}/thread`
- Guest network config:
  - Resource key: `guestnetwork` (or `guest_network`)
  - Fallback: `GET /2.2/networks/{networkId}/guestnetwork`
- Connected devices/clients list:
  - Resource key: `devices` (or `clients`)
  - Fallback: `GET /2.2/networks/{networkId}/devices`
- Profiles:
  - Resource key: `profiles`
  - Fallback: `GET /2.2/networks/{networkId}/profiles`
- Eeros list:
  - Resource key: `eeros`
  - Fallback: `GET /2.2/networks/{networkId}/eeros`
  - After listing, the app further expands each eero (see "Per-eero Expansion").
- AC compatibility:
  - Resource key: `ac_compat`
  - Fallback: `GET /2.2/networks/{networkId}/ac_compat`
- Blacklist:
  - Resource keys: `blacklist` or `device_blacklist`
  - Fallback: `GET /2.2/networks/{networkId}/blacklist`
- Diagnostics:
  - Resource key: `diagnostics`
  - Fallback: `GET /2.2/networks/{networkId}/diagnostics`
- Port forwards:
  - Resource key: `forwards`
  - Fallback: `GET /2.2/networks/{networkId}/forwards`
- Reservations:
  - Resource key: `reservations`
  - Fallback: `GET /2.2/networks/{networkId}/reservations`
- Routing bundle (reservations/forwards/pinholes, etc):
  - Resource key: `routing`
  - Fallback: `GET /2.2/networks/{networkId}/routing`
- Speedtest record:
  - Resource key: `speedtest`
  - Fallback: `GET /2.2/networks/{networkId}/speedtest`
- Updates:
  - Resource key: `updates`
  - Fallback: `GET /2.2/networks/{networkId}/updates`
- Support metadata:
  - Resource key: `support`
  - Fallback: `GET /2.2/networks/{networkId}/support`
- Insights + OUI check:
  - Resource key: `insights`
  - Fallback: `GET /2.2/networks/{networkId}/insights`
  - Resource key: `ouicheck`
  - Fallback: `GET /2.2/networks/{networkId}/ouicheck`
- Proxied nodes:
  - Resource key: `proxied_nodes`
  - Fallback: `GET /2.2/networks/{networkId}/proxied_nodes`

Notes:

- The set of resource keys the app considers "known" is in `EeroRouteCatalog.getResourceKeys`.
- The app uses `network.timezone.value` if present; otherwise falls back to the Mac timezone identifier.

### Activity / Data Usage Fetch

In addition to the "resources" above, the app fetches usage telemetry (best-effort; may be premium-gated).

All of these calls are built from `network.url` (an absolute URL) rather than hard-coded `/2.2/networks/{id}`:

- Network aggregate usage:
  - `GET {networkURL}/data_usage?start&end&cadence&timezone`
- Per-eero usage:
  - `GET {networkURL}/data_usage/eeros?start&end&cadence&timezone`
- Per-device usage rollups:
  - `GET {networkURL}/data_usage/devices?start&end&cadence&timezone`
- Per-device usage timeline (top-N devices only):
  - `GET {networkURL}/data_usage/devices/{mac}?start&end&cadence=hourly&timezone`

Query parameters:

- `start`, `end`: ISO8601 date strings with fractional seconds.
- `cadence`:
  - `day`: `hourly`
  - `week`: `daily`
  - `month`: `daily`
- `timezone`: e.g. `America/Los_Angeles`

Timeline behavior:

- The app chooses the **top 5** devices (scored by total download+upload bytes across available rollups) and fetches an hourly day window for those only.

### Channel Utilization (Radio Analytics)

- `GET {networkURL}/channel_utilization?start&end&granularity&gap_data_placeholder&timezone`

Current query shape:

- Window: last ~6 hours.
- `granularity=fifteen_minutes`
- `gap_data_placeholder=true`

The returned payload is parsed into `NetworkChannelUtilizationSummary` and then surfaced in Dashboard and Network views.

### Per-eero Expansion (Connections, Ports, Attachments)

After listing eeros for a network, the app expands each eero:

1. `GET <eero.url>` for each eero
2. If `eero.resources["connections"]` exists:
   - `GET <connections.url>`

The `connections` payload is used to enrich:

- Ethernet port/interface status (`connections.ports.interfaces[]`)
- Wireless attachments (`connections.wireless_devices[]`)
- Neighbor metadata (best-effort extraction of `display_name`, model, port name, etc.)

### "Realtime" Throughput Telemetry

Important: the app does **not** currently call a dedicated WAN-throughput endpoint.

Instead, `EeroControl` derives a "realtime" summary by summing per-client instantaneous usage fields:

- Source fields: `EeroClient.usage.down_mbps` and `EeroClient.usage.up_mbps` (parsed from the devices/clients list payload).
- Computed in `parseRealtimeSummary(_ clients: [EeroClient])`.
- Labeled as: `sourceLabel = "eero client telemetry"`.

This is a proxy for activity and may not equal WAN throughput (e.g., local LAN traffic can contribute depending on what the API reports).

## Mutating API Calls (Actions)

Actions are created in `Sources/EeroControl/State/AppState.swift` and executed via `EeroAPIClient.perform(_:)`.

### Guest Network

- `PUT /2.2/networks/{networkId}/guestnetwork`
  - Body: `{ "enabled": true|false }`

### Network Features / Settings

- Thread enable:
  - `PUT {threadResourceURL}/enable` (or fallback `PUT /2.2/networks/{networkId}/thread/enable`)
  - Body: `{ "enabled": true|false }`
- Ad blocking:
  - `POST /2.2/networks/{networkId}/dns_policies/adblock`
  - Body: `{ "enable": true|false }`
- Malware blocking:
  - `POST /2.2/networks/{networkId}/dns_policies/network`
  - Body: `{ "block_malware": true|false }`
- Other settings toggles (band steering, UPnP, WPA3, SQM, etc.):
  - `PUT {settingsResourceURL}` (fallback `PUT /2.2/networks/{networkId}/settings`)
  - Body: `{ "<key>": true|false }`

### Client Pause/Resume

- `PUT /2.3/networks/{networkId}/devices/{clientMac}`
  - Body: `{ "paused": true|false }`

### Profiles

- Pause/resume profile:
  - `PUT /2.2/networks/{networkId}/profiles/{profileId}`
  - Body: `{ "paused": true|false }`
- Content filters:
  - `POST /2.2/networks/{networkId}/dns_policies/profiles/{profileId}`
  - Body: `{ "<filter_key>": true|false }`
- Blocked apps list:
  - `PUT /2.2/networks/{networkId}/dns_policies/profiles/{profileId}/applications/blocked`
  - Body: `{ "applications": ["app1", "app2", ...] }`

### Eero Device Actions

- Status LED:
  - `PUT {device.resources["led_action"]}` (fallback `PUT /2.2/eeros/{eeroId}/led`)
  - Body: `{ "led_on": true|false }`
- Reboot eero:
  - `POST {device.resources["reboot"]}` (fallback `POST /2.2/eeros/{eeroId}/reboot`)
  - Body: `{}`

### Network Actions

- Reboot network:
  - `POST {network.resources["reboot"]}` (fallback `POST /2.2/networks/{networkId}/reboot`)
  - Body: `{}`
- Run speed test:
  - `POST {network.resources["speedtest"]}` (fallback `POST /2.2/networks/{networkId}/speedtest`)
  - Body: `{}`
- Run burst reporters:
  - `POST {network.resources["burst_reporters"]}` (fallback `POST /2.2/networks/{networkId}/burst_reporters`)
  - Body: `{}`

## Local (Offline) Probes and Telemetry

These are **not eero cloud API calls**. They are local checks intended to be useful when cloud access is down.

### Config

- Default gateway target: `192.168.4.1`
  - Stored in `AppSettings.gatewayAddress` and editable in Settings UI.

### Probe Suite (Shell Tools)

Implemented in `Sources/EeroControl/Services/OfflineConnectivityService.swift`:

- Default route probe:
  - `/sbin/route -n get default`
- Gateway reachability:
  - `/sbin/ping -c 1 -W 1000 <gateway>`
- DNS resolver check against router:
  - `/usr/bin/dig +time=1 +tries=1 @<gateway> eero.com A`
- NTP UDP port check (optional, non-fatal):
  - `/usr/bin/nc -u -z -w 1 <gateway> 123`
  - Failure is still treated as success with message "NTP no response (optional check)".

LAN health labeling:

- `LAN OK / Degraded / Down` is based primarily on **gateway + route** health.
- DNS is treated as informational so an upstream outage does not incorrectly mark LAN as down.

### Local Interface Throughput (Mac Default Route)

The app also measures local Mac interface throughput (again: not eero WAN telemetry).

Implemented in `Sources/EeroControl/State/AppState.swift`:

- Finds the default-route interface via `/sbin/route -n get default`
- Reads interface counters via `getifaddrs` (`if_data.ifi_ibytes` / `ifi_obytes`)
- Publishes an exponential-ish smoothing of bytes/sec to `ThroughputStore`

UI behavior:

- If `network.realtime` (client telemetry) is present, UI prefers it.
- Some surfaces may still fall back to local interface throughput when eero telemetry is unavailable; these should be treated as **Mac-local**.

## Known Caveats / Footguns

- The "realtime" numbers are derived from **client usage** fields, not from a WAN interface counter endpoint.
- Local interface throughput reflects the Mac's default-route interface (`en0`, etc.), not router-side traffic.
- This code intentionally uses server-provided `resources` where possible, but still has fallback hard-coded paths which may drift.

## Where to Look in Code

- Cloud API client + endpoints:
  - `Sources/EeroControl/Services/EeroAPIClient.swift`
- Action construction (mutations):
  - `Sources/EeroControl/State/AppState.swift`
  - `Sources/EeroControl/Models/ActionModels.swift`
- Offline probes:
  - `Sources/EeroControl/Services/OfflineConnectivityService.swift`
- Local throughput monitoring:
  - `Sources/EeroControl/State/AppState.swift` (`startLocalThroughputMonitoring()`)
