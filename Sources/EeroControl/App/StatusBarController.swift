import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let appState: AppState
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var displayView: StatusItemDisplayView?
    private var cancellables = Set<AnyCancellable>()

    init(appState: AppState) {
        self.appState = appState
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        super.init()

        popover.behavior = .transient
        popover.delegate = self

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp])
            button.title = ""
            button.attributedTitle = NSAttributedString(string: "")

            let displayView = StatusItemDisplayView()
            displayView.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(displayView)
            NSLayoutConstraint.activate([
                displayView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                displayView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                displayView.topAnchor.constraint(equalTo: button.topAnchor),
                displayView.bottomAnchor.constraint(equalTo: button.bottomAnchor)
            ])
            self.displayView = displayView
        }

        updateStatusDisplay()

        appState.$accountSnapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusDisplay()
            }
            .store(in: &cancellables)

        appState.$cloudState
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusDisplay()
            }
            .store(in: &cancellables)

        appState.$selectedNetworkID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusDisplay()
            }
            .store(in: &cancellables)

        appState.throughputStore.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusDisplay()
            }
            .store(in: &cancellables)
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.contentViewController = NSHostingController(
                rootView: StatusPopoverView()
                    .environmentObject(appState)
                    .environmentObject(appState.throughputStore)
            )
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func updateStatusDisplay() {
        guard let displayView else { return }

        let down: String
        let up: String

        if let realtime = appState.selectedNetwork?.realtime {
            down = "↓\(compactRateString(megabitsPerSecond: realtime.downloadMbps))"
            up = "↑\(compactRateString(megabitsPerSecond: realtime.uploadMbps))"
        } else if let snapshot = appState.throughputStore.snapshot {
            down = "↓\(compactRateString(bytesPerSecond: snapshot.downBytesPerSecond))"
            up = "↑\(compactRateString(bytesPerSecond: snapshot.upBytesPerSecond))"
        } else {
            down = "↓--"
            up = "↑--"
        }

        let warning: Bool = {
            switch appState.cloudState {
            case .reachable:
                return false
            case .degraded, .unreachable:
                return true
            case .unknown:
                return false
            }
        }()

        displayView.updateThroughput(down: down, up: up, warning: warning)
        statusItem.length = max(1, displayView.intrinsicContentSize.width)
    }

    private func compactRateString(megabitsPerSecond: Double) -> String {
        compactRateString(bitsPerSecond: max(0, megabitsPerSecond) * 1_000_000)
    }

    private func compactRateString(bytesPerSecond: Double) -> String {
        compactRateString(bitsPerSecond: max(0, bytesPerSecond) * 8)
    }

    private func compactRateString(bitsPerSecond: Double) -> String {
        let value: Double
        let suffix: String

        if bitsPerSecond >= 1_000_000_000 {
            value = bitsPerSecond / 1_000_000_000
            suffix = "G"
        } else if bitsPerSecond >= 1_000_000 {
            value = bitsPerSecond / 1_000_000
            suffix = "M"
        } else if bitsPerSecond >= 1_000 {
            value = bitsPerSecond / 1_000
            suffix = "K"
        } else {
            value = bitsPerSecond
            suffix = "b"
        }

        let formatted: String
        if value >= 100 {
            formatted = String(format: "%.0f", value)
        } else if value >= 10 {
            formatted = String(format: "%.1f", value)
        } else {
            formatted = String(format: "%.2f", value)
        }
        return "\(formatted)\(suffix)"
    }

    func popoverWillShow(_ notification: Notification) {
        appState.setPopoverVisible(true)
    }

    func popoverWillClose(_ notification: Notification) {
        appState.setPopoverVisible(false)
        popover.contentViewController = nil
    }
}

private final class StatusItemDisplayView: NSView {
    private let downLabel = NSTextField(labelWithString: "")
    private let upLabel = NSTextField(labelWithString: "")
    private let stack: NSStackView

    override init(frame frameRect: NSRect) {
        stack = NSStackView(views: [downLabel, upLabel])
        super.init(frame: frameRect)

        downLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        downLabel.alignment = .center

        upLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        upLabel.alignment = .center

        stack.orientation = .vertical
        stack.spacing = -1
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        updateThroughput(down: "↓--", up: "↑--", warning: false)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override var intrinsicContentSize: NSSize {
        let content = stack.fittingSize
        return NSSize(width: content.width + 2, height: content.height + 2)
    }

    func updateThroughput(down: String, up: String, warning: Bool) {
        downLabel.stringValue = down
        upLabel.stringValue = up
        downLabel.textColor = warning ? .systemOrange : .labelColor
        upLabel.textColor = warning ? .systemOrange : .secondaryLabelColor
        invalidateIntrinsicContentSize()
    }
}
