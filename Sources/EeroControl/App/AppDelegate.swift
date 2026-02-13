import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var statusBarController: StatusBarController?
  private var windowObserverToken: NSObjectProtocol?

  func applicationDidFinishLaunching(_ notification: Notification) {
    statusBarController = StatusBarController(appState: AppState.shared)
    AppState.shared.start()
    applyLiquidGlassWindowStyles()
    DispatchQueue.main.async { [weak self] in
      self?.applyLiquidGlassWindowStyles()
    }
    windowObserverToken = NotificationCenter.default.addObserver(
      forName: NSWindow.didBecomeKeyNotification,
      object: nil,
      queue: .main
    ) { [weak self] note in
      guard let window = note.object as? NSWindow else { return }
      self?.applyLiquidGlassWindowStyle(window)
    }
  }

  private func applyLiquidGlassWindowStyles() {
    NSApp.windows.forEach(applyLiquidGlassWindowStyle)
  }

  private func applyLiquidGlassWindowStyle(_ window: NSWindow) {
    let backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85)
    let backgroundCGColor = backgroundColor.cgColor
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.styleMask.insert(.fullSizeContentView)
    window.isOpaque = false
    window.backgroundColor = backgroundColor
    window.contentView?.wantsLayer = true
    window.contentView?.superview?.wantsLayer = true
    window.contentView?.superview?.layer?.backgroundColor = backgroundCGColor
    window.contentView?.layer?.backgroundColor = backgroundCGColor
    window.contentView?.layer?.isOpaque = false
    window.contentView?.superview?.layer?.isOpaque = false
    window.standardWindowButton(.closeButton)?.isHidden = false
    window.standardWindowButton(.miniaturizeButton)?.isHidden = false
    window.standardWindowButton(.zoomButton)?.isHidden = false

    addWindowGlassEffect(to: window)
  }

  private func addWindowGlassEffect(to window: NSWindow) {
    guard let contentView = window.contentView else { return }

    let existing = contentView.subviews.compactMap({ $0 as? WindowGlassEffectView })
    if !existing.isEmpty {
      existing.forEach { $0.configureForWindowGlass() }
      return
    }

    let effectView = WindowGlassEffectView()
    effectView.translatesAutoresizingMaskIntoConstraints = false
    effectView.configureForWindowGlass()
    contentView.addSubview(effectView, positioned: .below, relativeTo: contentView.subviews.first)
    NSLayoutConstraint.activate([
      effectView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      effectView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      effectView.topAnchor.constraint(equalTo: contentView.topAnchor),
      effectView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
    ])
    contentView.layoutSubtreeIfNeeded()
  }

  func applicationWillTerminate(_ notification: Notification) {
    if let token = windowObserverToken {
      NotificationCenter.default.removeObserver(token)
      windowObserverToken = nil
    }
  }
}

extension NSVisualEffectView {
  fileprivate func configureForWindowGlass() {
    material = .underWindowBackground
    blendingMode = .behindWindow
    state = .active
  }
}

private final class WindowGlassEffectView: NSVisualEffectView {}
