import Cocoa
import FlutterMacOS

/// Icarus draws its own title strip, so the window keeps only the native
/// traffic lights and lets the Flutter view extend under the title bar.
class MainFlutterWindow: NSWindow {
  /// Matches `kWindowStripHeight` in lib/widgets/window_chrome.dart.
  private let titleStripHeight: CGFloat = 40
  private var layoutObservers: [NSObjectProtocol] = []

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    styleMask.insert(.fullSizeContentView)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()

    observeTitleBarLayout()
    centerTrafficLights()
  }

  deinit {
    for observer in layoutObservers {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  override func layoutIfNeeded() {
    super.layoutIfNeeded()
    centerTrafficLights()
  }

  private func observeTitleBarLayout() {
    let names: [Notification.Name] = [
      NSWindow.didResizeNotification,
      NSWindow.didExitFullScreenNotification,
      NSWindow.didBecomeKeyNotification,
      NSWindow.didResignKeyNotification,
    ]
    for name in names {
      let observer = NotificationCenter.default.addObserver(
        forName: name, object: self, queue: .main
      ) { [weak self] _ in
        self?.centerTrafficLights()
      }
      layoutObservers.append(observer)
    }
  }

  /// AppKit lays the traffic lights out for its own 28pt title bar. Grow the
  /// title bar container to the strip's height and re-center the buttons in
  /// it, so they line up with the app's controls.
  private func centerTrafficLights() {
    if styleMask.contains(.fullScreen) { return }
    guard
      let closeButton = standardWindowButton(.closeButton),
      let titleBarView = closeButton.superview,
      let container = titleBarView.superview
    else { return }

    var containerFrame = container.frame
    if containerFrame.height != titleStripHeight {
      containerFrame.origin.y = frame.height - titleStripHeight
      containerFrame.size.height = titleStripHeight
      container.frame = containerFrame
    }

    let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    for type in buttons {
      guard let button = standardWindowButton(type) else { continue }
      var origin = button.frame.origin
      origin.y = (titleBarView.frame.height - button.frame.height) / 2
      button.setFrameOrigin(origin)
    }
  }
}
