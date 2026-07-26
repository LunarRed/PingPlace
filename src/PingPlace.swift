import ApplicationServices
import Cocoa
import OSLog
import ServiceManagement

enum ScreenEdge {
  case left, right
}

enum NotificationPosition: String, CaseIterable {
  case topLeft, topMiddle, topRight
  case middleLeft, deadCenter, middleRight
  case bottomLeft, bottomMiddle, bottomRight

  var displayName: String {
    switch self {
    case .topLeft: "Top Left"
    case .topMiddle: "Top Middle"
    case .topRight: "Top Right"
    case .middleLeft: "Middle Left"
    case .deadCenter: "Middle"
    case .middleRight: "Middle Right"
    case .bottomLeft: "Bottom Left"
    case .bottomMiddle: "Bottom Middle"
    case .bottomRight: "Bottom Right"
    }
  }

  var screenEdge: ScreenEdge? {
    switch self {
    case .topLeft, .middleLeft, .bottomLeft: .left
    case .topRight, .middleRight, .bottomRight: .right
    case .topMiddle, .deadCenter, .bottomMiddle: nil
    }
  }
}

private enum AppConstants {
  static let notificationCenterBundleID = "com.apple.notificationcenterui"
  static let childrenChangedNotification = "AXChildrenChanged"
  static let orderedChildrenAttribute = "AXOrderedChildren"
  static let widgetEditorButtonIdentifier = "widget-editor-button"
  static let widgetIdentifierPrefix = "widget-local:"
  static let maxAccessibilityNodesPerWindow = 10_000
  static let maxBannerContentNodes = 400
  static let maxBannerStackHeightFraction: CGFloat = 0.75
  static let placementRefreshInterval: TimeInterval = 1
  static let dockPadding: CGFloat = 30
  static let bannerRightPadding: CGFloat = 16
  static let edgePeekFraction: CGFloat = 0.15
  static let minimumEdgePeek: CGFloat = 12
  static let revealedHoverPadding: CGFloat = 48
  static let edgeSlideDuration: TimeInterval = 0.2
  static let edgeSlideInterval: TimeInterval = 1.0 / 120.0
  static let bannerSubroles: Set<String> = [
    "AXNotificationCenterBanner", "AXNotificationCenterAlert",
    "AXNotificationCenterNotification", "AXNotificationCenterBannerWindow",
  ]
  static let subsystem = "com.grimridge.PingPlace"
}

private enum DefaultsKey {
  static let menuBarIconHidden = "isMenuBarIconHidden"
  static let notificationPosition = "notificationPosition"
  static let notificationDisplay = "notificationDisplay"
  static let notificationDisplayName = "notificationDisplayName"
  static let edgeHidingEnabled = "isEdgeHidingEnabled"
  static let debugLoggingEnabled = "debugLoggingEnabled"
}

private enum LogLevel: String {
  case info = "INFO"
  case debug = "DEBUG"
  case error = "ERROR"
}

extension AXUIElement {
  fileprivate func attribute<T>(_ name: String, as _: T.Type = T.self) -> T? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else {
      return nil
    }
    return value as? T
  }

  fileprivate func point(for attributeName: String) -> CGPoint? {
    guard
      let value = attribute(attributeName, as: AXValue.self),
      AXValueGetType(value) == .cgPoint
    else {
      return nil
    }
    var point = CGPoint.zero
    AXValueGetValue(value, .cgPoint, &point)
    return point
  }

  fileprivate func size(for attributeName: String) -> CGSize? {
    guard
      let value = attribute(attributeName, as: AXValue.self),
      AXValueGetType(value) == .cgSize
    else {
      return nil
    }
    var size = CGSize.zero
    AXValueGetValue(value, .cgSize, &size)
    return size
  }

  fileprivate func frame() -> CGRect? {
    guard let origin = point(for: kAXPositionAttribute), let size = size(for: kAXSizeAttribute)
    else {
      return nil
    }
    return CGRect(origin: origin, size: size)
  }

  fileprivate func isSettable(_ attribute: String) -> Bool {
    var settable: DarwinBoolean = false
    let result = AXUIElementIsAttributeSettable(self, attribute as CFString, &settable)
    return result == .success && settable.boolValue
  }

  fileprivate func setPosition(_ point: CGPoint) -> AXError {
    var point = point
    guard let value = AXValueCreate(.cgPoint, &point) else { return .failure }
    return AXUIElementSetAttributeValue(self, kAXPositionAttribute as CFString, value)
  }

  fileprivate func children() -> [AXUIElement] {
    let direct = attribute(kAXChildrenAttribute, as: [AXUIElement].self) ?? []
    let ordered = attribute(AppConstants.orderedChildrenAttribute, as: [AXUIElement].self) ?? []
    var seen = Set<AXUIElement>()
    return (direct + ordered).filter { seen.insert($0).inserted }
  }
}

extension NSScreen {
  fileprivate var displayUUID: String? {
    guard
      let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
      let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue()
    else {
      return nil
    }
    return CFUUIDCreateString(nil, uuid) as String?
  }

  fileprivate static func menuTitles() -> [(uuid: String, title: String)] {
    var totals = [String: Int]()
    for screen in screens { totals[screen.localizedName, default: 0] += 1 }

    var seen = [String: Int]()
    return screens.compactMap { screen in
      guard let uuid = screen.displayUUID else { return nil }
      let name = screen.localizedName
      guard totals[name, default: 0] > 1 else { return (uuid, name) }
      seen[name, default: 0] += 1
      return (uuid, "\(name) (\(seen[name, default: 0]))")
    }
  }
}

private enum NotificationCenterWindowKind {
  case panel
  case desktopWidget
  case banners([AXUIElement])
  case other
  case indeterminate
}

private struct EdgeSlide {
  let fromX: CGFloat
  let toX: CGFloat
  let y: CGFloat
  let startedAt: TimeInterval
  let duration: TimeInterval

  func progress(at now: TimeInterval) -> Double {
    guard duration > 0 else { return 1 }
    return min(1, max(0, (now - startedAt) / duration))
  }

  // Ease out so the banner leaves the edge at once and settles gently at the other end.
  func origin(at now: TimeInterval) -> CGPoint {
    let eased = 1 - pow(1 - progress(at: now), 3)
    return CGPoint(x: fromX + (toX - fromX) * eased, y: y)
  }
}

private struct EdgeHidingState {
  let revealedOrigin: CGPoint
  let hiddenOrigin: CGPoint
  let revealedBannerFrame: CGRect
  let hiddenBannerFrame: CGRect
  var isRevealed: Bool

  var origin: CGPoint {
    isRevealed ? revealedOrigin : hiddenOrigin
  }

  // Revealing takes the sliver alone, but staying revealed takes the whole banner plus the sliver,
  // so the pointer never lands in a gap that hides the banner and immediately shows it again.
  var hoverZone: CGRect {
    guard isRevealed else { return hiddenBannerFrame }
    let padding = AppConstants.revealedHoverPadding
    return revealedBannerFrame.insetBy(dx: -padding, dy: -padding).union(hiddenBannerFrame)
  }
}

private struct WindowPlacementState {
  let originalOrigin: CGPoint
  let baselineWindowFrame: CGRect
  let baselineBannerFrame: CGRect
  var edgeHiding: EdgeHidingState?
}

extension AXError {
  fileprivate var name: String {
    switch self {
    case .success: "success"
    case .failure: "failure"
    case .illegalArgument: "illegalArgument"
    case .invalidUIElement: "invalidUIElement"
    case .invalidUIElementObserver: "invalidUIElementObserver"
    case .cannotComplete: "cannotComplete"
    case .attributeUnsupported: "attributeUnsupported"
    case .actionUnsupported: "actionUnsupported"
    case .notificationUnsupported: "notificationUnsupported"
    case .notImplemented: "notImplemented"
    case .notificationAlreadyRegistered: "notificationAlreadyRegistered"
    case .notificationNotRegistered: "notificationNotRegistered"
    case .apiDisabled: "apiDisabled"
    case .noValue: "noValue"
    case .parameterizedAttributeUnsupported: "parameterizedAttributeUnsupported"
    case .notEnoughPrecision: "notEnoughPrecision"
    @unknown default: "unknown(\(rawValue))"
    }
  }
}

extension Logger {
  fileprivate static let app = Logger(subsystem: AppConstants.subsystem, category: "app")
}

private func axObserverCallback(
  _: AXObserver, _ element: AXUIElement, _ notification: CFString,
  _ refcon: UnsafeMutableRawPointer?
) {
  guard let refcon else { return }
  let appDelegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
  appDelegate.handleAXNotification(notification as String, element: element)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  private var axObserver: AXObserver?
  private var statusItem: NSStatusItem?
  private var observedWindows = Set<AXUIElement>()
  private var observedBanners = Set<AXUIElement>()
  private var lastPlacementRefresh: TimeInterval = 0
  private var placementByWindow = [AXUIElement: WindowPlacementState]()
  private var edgeHoverMonitor: Any?
  private var slideByWindow = [AXUIElement: EdgeSlide]()
  private var slideTimer: Timer?
  private weak var edgeHidingItem: NSMenuItem?

  private let logger = Logger.app
  private let logFileURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/PingPlace.log")
  private var isIconHidden = UserDefaults.standard.bool(forKey: DefaultsKey.menuBarIconHidden)
  private var isEdgeHidingEnabled = UserDefaults.standard.bool(
    forKey: DefaultsKey.edgeHidingEnabled)
  private var isDebugLoggingEnabled: Bool {
    UserDefaults.standard.bool(forKey: DefaultsKey.debugLoggingEnabled)
  }

  private var currentPosition: NotificationPosition = {
    UserDefaults.standard.string(forKey: DefaultsKey.notificationPosition)
      .flatMap(NotificationPosition.init(rawValue:)) ?? .topMiddle
  }()

  private var selectedDisplayUUID: String? = {
    UserDefaults.standard.string(forKey: DefaultsKey.notificationDisplay)
      .flatMap { $0.isEmpty ? nil : $0 }
  }()

  private var selectedDisplayName: String? = {
    UserDefaults.standard.string(forKey: DefaultsKey.notificationDisplayName)
  }()

  func launch() {
    prepareLogFile()
    info("Launch started")
    guard requestAccessibilityIfNeeded() else {
      NSApp.terminate(nil)
      return
    }
    setupAXObserver()
    if !isIconHidden { setupStatusItem() }
    NotificationCenter.default.addObserver(
      self, selector: #selector(screenParametersChanged),
      name: NSApplication.didChangeScreenParametersNotification, object: nil)
    moveAll()
  }

  @objc private func screenParametersChanged() {
    info("Screen configuration changed, screens=\(NSScreen.screens.count)")
    if statusItem != nil { statusItem?.menu = buildMenu() }
    moveAll()
  }

  func applicationWillBecomeActive(_: Notification) {
    guard isIconHidden else { return }
    isIconHidden = false
    UserDefaults.standard.set(false, forKey: DefaultsKey.menuBarIconHidden)
    setupStatusItem()
  }

  private func requestAccessibilityIfNeeded() -> Bool {
    let options =
      [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }

  private var notificationCenterApp: NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first {
      $0.bundleIdentifier == AppConstants.notificationCenterBundleID
    }
  }

  private var notificationCenterElement: AXUIElement? {
    notificationCenterApp.map { AXUIElementCreateApplication($0.processIdentifier) }
  }

  private func setupAXObserver() {
    guard let app = notificationCenterApp, let appElement = notificationCenterElement else {
      info("Notification Center not running")
      return
    }

    var obs: AXObserver?
    guard AXObserverCreate(app.processIdentifier, axObserverCallback, &obs) == .success, let obs
    else {
      error("Failed to create AXObserver")
      return
    }

    axObserver = obs
    CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)

    register(
      kAXWindowCreatedNotification as String, for: appElement, label: "Notification Center app")
    register(
      AppConstants.childrenChangedNotification, for: appElement, label: "Notification Center app")
    refreshWindowObservers()
    info("AXObserver ready for Notification Center pid=\(app.processIdentifier)")
  }

  private var notificationCenterWindows: [AXUIElement] {
    notificationCenterElement?.attribute(kAXWindowsAttribute, as: [AXUIElement].self) ?? []
  }

  private func register(_ notification: String, for element: AXUIElement, label: String) {
    guard let axObserver else { return }
    let result = AXObserverAddNotification(
      axObserver, element, notification as CFString, Unmanaged.passUnretained(self).toOpaque())

    switch result {
    case .success, .notificationAlreadyRegistered:
      debug("Registered \(notification) for \(label)")
    case .notificationUnsupported:
      debug("Notification unsupported \(notification) for \(label)")
    default:
      error("Failed to register \(notification) for \(label) result=\(result.name)")
    }
  }

  private func refreshWindowObservers() {
    let currentWindows = Set(notificationCenterWindows)
    observedWindows.formIntersection(currentWindows)
    placementByWindow = placementByWindow.filter { currentWindows.contains($0.key) }
    slideByWindow = slideByWindow.filter { currentWindows.contains($0.key) }

    for window in currentWindows {
      guard observedWindows.insert(window).inserted else { continue }
      register(
        AppConstants.childrenChangedNotification, for: window, label: "Notification Center window")
      register(kAXCreatedNotification as String, for: window, label: "Notification Center window")
      register(
        kAXUIElementDestroyedNotification as String, for: window,
        label: "Notification Center window")
    }
  }

  fileprivate func handleAXNotification(_ notification: String, element: AXUIElement) {
    debug("Observed \(notification) on \(summary(for: element))")
    refreshWindowObservers()
    moveAll()
  }

  private func classify(_ root: AXUIElement) -> NotificationCenterWindowKind {
    var pending = [root]
    var visited = Set<AXUIElement>()
    var containsDesktopWidget = false
    var banners = [AXUIElement]()

    while let element = pending.popLast() {
      guard visited.insert(element).inserted else { continue }
      guard visited.count <= AppConstants.maxAccessibilityNodesPerWindow else {
        return .indeterminate
      }

      if let identifier = element.attribute(kAXIdentifierAttribute, as: String.self) {
        if identifier == AppConstants.widgetEditorButtonIdentifier {
          return .panel
        }
        if identifier.hasPrefix(AppConstants.widgetIdentifierPrefix) {
          containsDesktopWidget = true
        }
      }

      if let subrole = element.attribute(kAXSubroleAttribute, as: String.self),
        AppConstants.bannerSubroles.contains(subrole)
      {
        banners.append(element)
      }

      pending.append(contentsOf: element.children().reversed())
    }

    if containsDesktopWidget { return .desktopWidget }
    if !banners.isEmpty { return .banners(banners) }
    return .other
  }

  // What a banner reports for itself can fall well short of what it puts on screen, so walk its
  // subtree for the real bounds. Anything wider than the banner is a backdrop rather than a card
  // and would stretch the result across the whole window.
  private func contentBounds(of root: AXUIElement, maxWidth: CGFloat) -> CGRect? {
    var pending = [root]
    var visited = Set<AXUIElement>()
    var bounds: CGRect?

    while let element = pending.popLast() {
      guard visited.insert(element).inserted else { continue }
      guard visited.count <= AppConstants.maxBannerContentNodes else { break }

      if let frame = element.frame(), frame.width > 0, frame.height > 0, frame.width <= maxWidth {
        bounds = bounds.map { $0.union(frame) } ?? frame
      }

      pending.append(contentsOf: element.children())
    }

    return bounds
  }

  private func summary(for element: AXUIElement) -> String {
    let role = element.attribute(kAXRoleAttribute, as: String.self) ?? "?"
    let subrole = element.attribute(kAXSubroleAttribute, as: String.self) ?? "?"
    let title = element.attribute(kAXTitleAttribute, as: String.self) ?? ""
    return "role=\(role) subrole=\(subrole) title=\(title)"
  }

  private func move(_ window: AXUIElement) {
    let banners: [AXUIElement]
    switch classify(window) {
    case .panel:
      restoreWindowIfNeeded(window, reason: "Notification Center panel opened")
      debug("Skipping Notification Center panel state")
      return
    case .desktopWidget:
      debug("Skipping desktop widget window")
      return
    case .banners(let elements):
      banners = elements
    case .other:
      restoreWindowIfNeeded(window, reason: "No banner visible")
      debug("Skipping window without banner")
      return
    case .indeterminate:
      error(
        "Skipping window after visiting more than \(AppConstants.maxAccessibilityNodesPerWindow) accessibility nodes"
      )
      return
    }

    // One app coalesces its notifications into a stack, and cards then come and go inside that
    // element rather than under the window, so the window never reports children changing. Watch
    // the banners themselves or a growing stack goes unnoticed.
    for banner in banners where observedBanners.insert(banner).inserted {
      register(AppConstants.childrenChangedNotification, for: banner, label: "banner")
      register(kAXResizedNotification as String, for: banner, label: "banner")
    }

    guard
      let banner = banners.first,
      let bannerFrame = banner.frame(),
      let windowFrame = window.frame()
    else {
      restoreWindowIfNeeded(window, reason: "No banner visible")
      debug("Skipping window without banner")
      return
    }


    guard window.isSettable(kAXPositionAttribute) else {
      debug("Notification Center window position not settable")
      return
    }

    let existingPlacement = placementByWindow[window]
    var placement =
      existingPlacement
      ?? WindowPlacementState(
        originalOrigin: windowFrame.origin,
        baselineWindowFrame: windowFrame,
        baselineBannerFrame: bannerFrame
      )

    if existingPlacement == nil {
      debug(
        "Captured baseline window=\(NSStringFromRect(windowFrame)) banner=\(NSStringFromRect(bannerFrame))"
      )
    }

    guard
      let revealedOrigin = targetOrigin(
        for: placement.baselineWindowFrame,
        bannerFrame: placement.baselineBannerFrame
      )
    else {
      debug("Skipping window without containing screen for banner")
      return
    }

    let hideOffset = edgeHideOffset(
      windowFrame: placement.baselineWindowFrame, bannerFrame: placement.baselineBannerFrame)
    placement.edgeHiding = hideOffset.map { offset in
      // Several apps stack their cards into one window that moves as a unit, and the element the
      // placement is built on covers only the first card, so hit testing it alone leaves the rest
      // of the stack dead to the pointer. Measure what the banners actually draw instead. Only
      // the vertical extent is taken from that, since a card still sliding in reports an x out at
      // the screen edge that would drag the zone far too wide.
      let drawn = banners.compactMap { contentBounds(of: $0, maxWidth: bannerFrame.width + 1) }
        .reduce(bannerFrame) { $0.union($1) }
      // Anything taller than most of the window is a container that slipped through rather than a
      // run of cards, and left alone it would reveal the banner whenever the pointer went near
      // the edge at any height.
      let maxHeight = windowFrame.height * AppConstants.maxBannerStackHeightFraction
      let hoverFrame = CGRect(
        x: bannerFrame.minX, y: drawn.minY,
        width: bannerFrame.width, height: min(drawn.height, maxHeight))
      debug(
        "Edge hover zone banners=\(banners.count) drawn=\(NSStringFromRect(drawn)) zone=\(NSStringFromRect(hoverFrame))"
      )

      let revealedBannerFrame = projectedBannerFrame(
        windowOrigin: revealedOrigin, windowFrame: windowFrame, bannerFrame: hoverFrame)
      return EdgeHidingState(
        revealedOrigin: revealedOrigin,
        hiddenOrigin: CGPoint(x: revealedOrigin.x + offset, y: revealedOrigin.y),
        revealedBannerFrame: revealedBannerFrame,
        hiddenBannerFrame: revealedBannerFrame.offsetBy(dx: offset, dy: 0),
        isRevealed: existingPlacement?.edgeHiding?.isRevealed ?? false
      )
    }

    let target = placement.edgeHiding?.origin ?? revealedOrigin

    // A slide already heading for this exact spot owns the window until it lands, otherwise every
    // accessibility notification arriving mid slide would snap the banner to the end.
    if let slide = slideByWindow[window], abs(slide.toX - target.x) < 0.5,
      abs(slide.y - target.y) < 0.5
    {
      placementByWindow[window] = placement
      debug("Left window position to the slide in progress target=\(NSStringFromPoint(target))")
      return
    }

    slideByWindow.removeValue(forKey: window)
    let result = window.setPosition(target)
    let updatedFrame = window.frame()
    if result == .success {
      placementByWindow[window] = placement
    }
    debug(
      "Set window position result=\(result.name) target=\(NSStringFromPoint(target)) edgeHidden=\(placement.edgeHiding.map { !$0.isRevealed } ?? false) after=\(updatedFrame.map(NSStringFromRect) ?? "nil")"
    )
  }

  private func moveAll() {
    refreshPlacements()
    if placementByWindow.isEmpty { observedBanners.removeAll() }
    updateEdgeHoverState()
    syncEdgeHoverMonitor()
    syncSlideTimer()
  }

  private func refreshPlacements() {
    notificationCenterWindows.forEach(move)
    lastPlacementRefresh = CACurrentMediaTime()
  }

  private func restoreWindowIfNeeded(_ window: AXUIElement, reason: String) {
    guard let placement = placementByWindow[window] else { return }
    slideByWindow.removeValue(forKey: window)
    let result = window.setPosition(placement.originalOrigin)
    let updatedFrame = window.frame()
    debug(
      "Restored window position reason=\(reason) result=\(result.name) target=\(NSStringFromPoint(placement.originalOrigin)) after=\(updatedFrame.map(NSStringFromRect) ?? "nil")"
    )
    if result == .success {
      placementByWindow.removeValue(forKey: window)
    }
  }

  private var primaryMaxY: CGFloat {
    NSScreen.screens.first?.frame.maxY ?? 0
  }

  private func cgFrame(of screen: NSScreen) -> CGRect {
    CGRect(
      x: screen.frame.minX, y: primaryMaxY - screen.frame.maxY,
      width: screen.frame.width, height: screen.frame.height)
  }

  private func containingScreen(for windowFrame: CGRect) -> NSScreen? {
    let appKitPoint = CGPoint(
      x: windowFrame.midX,
      y: primaryMaxY - (windowFrame.minY + windowFrame.height / 2)
    )
    return NSScreen.screens.first { $0.frame.contains(appKitPoint) }
  }

  private func destinationScreen(for windowFrame: CGRect) -> NSScreen? {
    if let selectedDisplayUUID {
      if let screen = NSScreen.screens.first(where: { $0.displayUUID == selectedDisplayUUID }) {
        return screen
      }
      debug("Selected display not connected uuid=\(selectedDisplayUUID)")
    }
    return containingScreen(for: windowFrame) ?? NSScreen.screens.first
  }

  private func bannerInset(windowFrame: CGRect, bannerFrame: CGRect) -> (
    localX: CGFloat, padding: CGFloat
  ) {
    let localX = max(0, windowFrame.width - bannerFrame.width - AppConstants.bannerRightPadding)
    return (localX, max(0, windowFrame.width - (localX + bannerFrame.width)))
  }

  private func targetOrigin(for windowFrame: CGRect, bannerFrame: CGRect) -> CGPoint? {
    guard let screen = destinationScreen(for: windowFrame) else { return nil }
    let screenFrame = cgFrame(of: screen)

    let (localBannerX, rightPadding) = bannerInset(
      windowFrame: windowFrame, bannerFrame: bannerFrame)

    let bannerX: CGFloat
    switch currentPosition {
    case .topLeft, .middleLeft, .bottomLeft:
      bannerX = screenFrame.minX + rightPadding
    case .topMiddle, .deadCenter, .bottomMiddle:
      bannerX = screenFrame.minX + (screenFrame.width - bannerFrame.width) / 2
    case .topRight, .middleRight, .bottomRight:
      bannerX = screenFrame.maxX - bannerFrame.width - rightPadding
    }

    let dockSize = screen.frame.height - screen.visibleFrame.height
    let bannerY: CGFloat
    switch currentPosition {
    case .topLeft, .topMiddle, .topRight:
      bannerY = screenFrame.minY
    case .middleLeft, .deadCenter, .middleRight:
      bannerY =
        screenFrame.minY + (screenFrame.height - bannerFrame.height) / 2 - dockSize
        - AppConstants.dockPadding
    case .bottomLeft, .bottomMiddle, .bottomRight:
      bannerY = screenFrame.maxY - bannerFrame.height - dockSize - AppConstants.dockPadding
    }

    let target = CGPoint(x: bannerX - localBannerX, y: bannerY)

    debug(
      "targetOrigin position=\(currentPosition.rawValue) display=\(screen.localizedName) window=\(NSStringFromRect(windowFrame)) banner=\(NSStringFromRect(bannerFrame)) screenCG=\(NSStringFromRect(screenFrame)) dock=\(dockSize) localBannerX=\(localBannerX) rightPadding=\(rightPadding) target=\(NSStringFromPoint(target))"
    )

    return target
  }

  // The banner sits at a fixed offset inside its window, so a window origin tells us exactly where
  // the banner will land. Its measured x is unreliable while the banner slides in, hence the
  // derived inset; the vertical offset holds steady throughout.
  private func projectedBannerFrame(
    windowOrigin: CGPoint, windowFrame: CGRect, bannerFrame: CGRect
  ) -> CGRect {
    CGRect(
      x: windowOrigin.x + bannerInset(windowFrame: windowFrame, bannerFrame: bannerFrame).localX,
      y: windowOrigin.y + (bannerFrame.minY - windowFrame.minY),
      width: bannerFrame.width,
      height: bannerFrame.height)
  }

  private func edgeHideOffset(windowFrame: CGRect, bannerFrame: CGRect) -> CGFloat? {
    guard isEdgeHidingEnabled, let edge = currentPosition.screenEdge else { return nil }

    let peek = max(
      bannerFrame.width * AppConstants.edgePeekFraction, AppConstants.minimumEdgePeek)
    let padding = bannerInset(windowFrame: windowFrame, bannerFrame: bannerFrame).padding
    let distance = bannerFrame.width + padding - peek
    guard distance > 0 else { return nil }

    return edge == .right ? distance : -distance
  }

  // Banner frames come from the accessibility API in screen space, which puts the origin at the
  // top left of the primary display. NSEvent.mouseLocation uses AppKit's bottom left origin.
  private var pointerLocationInScreenSpace: CGPoint {
    let location = NSEvent.mouseLocation
    return CGPoint(x: location.x, y: primaryMaxY - location.y)
  }

  private func updateEdgeHoverState() {
    // Watching the banners should catch a stack changing shape, but the pointer is the one thing
    // guaranteed to be moving when the zones matter, so use it to bound how stale they can get.
    if !placementByWindow.isEmpty,
      CACurrentMediaTime() - lastPlacementRefresh >= AppConstants.placementRefreshInterval
    {
      refreshPlacements()
    }

    let pointer = pointerLocationInScreenSpace
    for (window, placement) in placementByWindow {
      guard let edgeHiding = placement.edgeHiding else { continue }
      let shouldReveal = edgeHiding.hoverZone.contains(pointer)
      guard shouldReveal != edgeHiding.isRevealed else { continue }

      placementByWindow[window]?.edgeHiding?.isRevealed = shouldReveal
      startEdgeSlide(window)
    }
  }

  private func startEdgeSlide(_ window: AXUIElement) {
    guard let edgeHiding = placementByWindow[window]?.edgeHiding else { return }
    let destination = edgeHiding.origin
    let fallbackX = edgeHiding.isRevealed ? edgeHiding.hiddenOrigin.x : edgeHiding.revealedOrigin.x
    let fromX = window.frame()?.origin.x ?? fallbackX

    let travel = abs(destination.x - fromX)
    let fullTravel = abs(edgeHiding.revealedOrigin.x - edgeHiding.hiddenOrigin.x)
    guard travel >= 0.5, fullTravel > 0 else {
      slideByWindow.removeValue(forKey: window)
      _ = window.setPosition(destination)
      syncSlideTimer()
      return
    }

    // Reversing part way through covers less ground, so shorten the slide to match and keep the
    // banner moving at a steady speed whichever way it is going.
    slideByWindow[window] = EdgeSlide(
      fromX: fromX, toX: destination.x, y: destination.y,
      startedAt: CACurrentMediaTime(),
      duration: AppConstants.edgeSlideDuration * min(1, travel / fullTravel))
    syncSlideTimer()

    debug(
      "Sliding banner \(edgeHiding.isRevealed ? "into view" : "to the edge") from=\(fromX) to=\(destination.x)"
    )
  }

  private func stepSlides() {
    let now = CACurrentMediaTime()
    for (window, slide) in slideByWindow {
      _ = window.setPosition(slide.origin(at: now))
      guard slide.progress(at: now) >= 1 else { continue }
      slideByWindow.removeValue(forKey: window)
    }
    syncSlideTimer()
  }

  private func syncSlideTimer() {
    if !slideByWindow.isEmpty, slideTimer == nil {
      let timer = Timer(timeInterval: AppConstants.edgeSlideInterval, repeats: true) {
        [weak self] _ in
        self?.stepSlides()
      }
      RunLoop.main.add(timer, forMode: .common)
      slideTimer = timer
    } else if slideByWindow.isEmpty, let slideTimer {
      slideTimer.invalidate()
      self.slideTimer = nil
    }
  }

  private func syncEdgeHoverMonitor() {
    let isNeeded = placementByWindow.values.contains { $0.edgeHiding != nil }

    if isNeeded, edgeHoverMonitor == nil {
      edgeHoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) {
        [weak self] _ in
        self?.updateEdgeHoverState()
      }
      debug("Started tracking the pointer for edge hiding")
    } else if !isNeeded, let edgeHoverMonitor {
      NSEvent.removeMonitor(edgeHoverMonitor)
      self.edgeHoverMonitor = nil
      debug("Stopped tracking the pointer for edge hiding")
    }
  }

  private func setupStatusItem() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let btn = statusItem?.button, let icon = NSImage(named: "MenuBarIcon") {
      icon.isTemplate = true
      icon.size = NSSize(width: 18, height: 18)
      btn.image = icon
      btn.imagePosition = .imageOnly
      btn.imageScaling = .scaleProportionallyDown
    }
    statusItem?.menu = buildMenu()
  }

  private func buildMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    for pos in NotificationPosition.allCases {
      let item = NSMenuItem(
        title: pos.displayName, action: #selector(selectPosition(_:)), keyEquivalent: "")
      item.representedObject = pos
      item.state = pos == currentPosition ? .on : .off
      menu.addItem(item)
    }
    menu.addItem(.separator())
    let displayItem = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
    displayItem.submenu = buildDisplayMenu()
    menu.addItem(displayItem)

    let edgeItem = NSMenuItem(
      title: "Hide at Screen Edge", action: #selector(toggleEdgeHiding(_:)), keyEquivalent: "")
    edgeItem.toolTip =
      "Parks notifications past the left or right edge with a sliver still showing. Hover the sliver to bring one back."
    edgeItem.state = isEdgeHidingEnabled ? .on : .off
    edgeItem.isEnabled = currentPosition.screenEdge != nil
    menu.addItem(edgeItem)
    edgeHidingItem = edgeItem

    let loginItem = NSMenuItem(
      title: "Launch at Login", action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
    loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    menu.addItem(loginItem)
    menu.addItem(
      NSMenuItem(title: "Hide Menu Bar Icon", action: #selector(hideIcon), keyEquivalent: ""))
    menu.addItem(.separator())

    let donate = NSMenuItem(title: "Donate", action: nil, keyEquivalent: "")
    let dm = NSMenu()
    dm.addItem(
      NSMenuItem(title: "Ko-fi", action: #selector(openDonationLink(_:)), keyEquivalent: ""))
    dm.addItem(
      NSMenuItem(
        title: "Buy Me a Coffee", action: #selector(openDonationLink(_:)), keyEquivalent: ""))
    donate.submenu = dm
    menu.addItem(donate)

    menu.addItem(NSMenuItem(title: "About", action: #selector(showAbout), keyEquivalent: ""))
    menu.addItem(
      NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: ""))
    return menu
  }

  private func buildDisplayMenu() -> NSMenu {
    let menu = NSMenu()
    let automatic = NSMenuItem(
      title: "Automatic", action: #selector(selectDisplay(_:)), keyEquivalent: "")
    automatic.representedObject = ""
    automatic.state = selectedDisplayUUID == nil ? .on : .off
    menu.addItem(automatic)
    menu.addItem(.separator())

    let displays = NSScreen.menuTitles()
    for display in displays {
      let item = NSMenuItem(
        title: display.title, action: #selector(selectDisplay(_:)), keyEquivalent: "")
      item.representedObject = display.uuid
      item.state = display.uuid == selectedDisplayUUID ? .on : .off
      menu.addItem(item)
    }

    if let selectedDisplayUUID, !displays.contains(where: { $0.uuid == selectedDisplayUUID }) {
      let item = NSMenuItem(
        title: "\(selectedDisplayName ?? "Selected Display") (Not Connected)",
        action: #selector(selectDisplay(_:)), keyEquivalent: "")
      item.representedObject = selectedDisplayUUID
      item.state = .on
      menu.addItem(item)
    }

    return menu
  }

  @objc private func selectPosition(_ sender: NSMenuItem) {
    guard let pos = sender.representedObject as? NotificationPosition else { return }
    currentPosition = pos
    UserDefaults.standard.set(pos.rawValue, forKey: DefaultsKey.notificationPosition)
    for item in sender.menu?.items ?? [] {
      guard let itemPosition = item.representedObject as? NotificationPosition else { continue }
      item.state = itemPosition == pos ? .on : .off
    }
    edgeHidingItem?.isEnabled = pos.screenEdge != nil
    moveAll()
  }

  @objc private func toggleEdgeHiding(_ sender: NSMenuItem) {
    isEdgeHidingEnabled.toggle()
    UserDefaults.standard.set(isEdgeHidingEnabled, forKey: DefaultsKey.edgeHidingEnabled)
    sender.state = isEdgeHidingEnabled ? .on : .off
    info("Edge hiding \(isEdgeHidingEnabled ? "enabled" : "disabled")")
    moveAll()
  }

  @objc private func selectDisplay(_ sender: NSMenuItem) {
    guard let uuid = sender.representedObject as? String else { return }
    let name = NSScreen.screens.first { $0.displayUUID == uuid }?.localizedName

    selectedDisplayUUID = uuid.isEmpty ? nil : uuid
    if uuid.isEmpty || name != nil { selectedDisplayName = name }

    UserDefaults.standard.set(uuid, forKey: DefaultsKey.notificationDisplay)
    UserDefaults.standard.set(selectedDisplayName, forKey: DefaultsKey.notificationDisplayName)

    sender.menu?.items.forEach {
      guard let itemUUID = $0.representedObject as? String else { return }
      $0.state = itemUUID == uuid ? .on : .off
    }
    info("Display selection \(selectedDisplayName ?? "Automatic")")
    moveAll()
  }

  @objc private func toggleLoginItem(_ sender: NSMenuItem) {
    do {
      if SMAppService.mainApp.status == .enabled {
        try SMAppService.mainApp.unregister()
        sender.state = .off
      } else {
        try SMAppService.mainApp.register()
        sender.state = .on
      }
    } catch {
      let a = NSAlert()
      a.messageText = "Error"
      a.informativeText = error.localizedDescription
      a.runModal()
    }
  }

  @objc private func hideIcon() {
    let alert = NSAlert()
    alert.messageText = "Hide Menu Bar Icon"
    alert.informativeText = "The menu bar icon will be hidden. Launch PingPlace again to show it."
    alert.addButton(withTitle: "Hide Icon")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    isIconHidden = true
    UserDefaults.standard.set(true, forKey: DefaultsKey.menuBarIconHidden)
    statusItem = nil
  }

  @objc private func openDonationLink(_ sender: NSMenuItem) {
    let urls = [
      "Ko-fi": "https://ko-fi.com/wadegrimridge",
      "Buy Me a Coffee": "https://www.buymeacoffee.com/wadegrimridge",
    ]
    if let url = urls[sender.title].flatMap(URL.init) { NSWorkspace.shared.open(url) }
  }

  @objc private func showAbout() {
    let windowWidth: CGFloat = 320
    let windowHeight: CGFloat = 220
    let horizontalPadding: CGFloat = 24
    let iconSize: CGFloat = 80
    let titleHeight: CGFloat = 22
    let lineHeight: CGFloat = 18
    let linkHeight: CGFloat = 20
    let copyrightHeight: CGFloat = 16

    let win = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    win.title = "About PingPlace"
    win.center()
    win.delegate = self

    let content = NSView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight))
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "N/A"
    let copyright = Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? ""

    let contentWidth = windowWidth - (horizontalPadding * 2)
    let footerSpacing: CGFloat = 4
    let lineSpacing: CGFloat = 2
    let titleSpacing: CGFloat = 6

    let contentStackHeight =
      copyrightHeight + footerSpacing + linkHeight + lineSpacing + lineHeight + lineSpacing
      + lineHeight + lineSpacing + titleHeight + titleSpacing + iconSize
    let verticalPadding = max(12, floor((windowHeight - contentStackHeight) / 2))

    let copyrightY = verticalPadding
    let linkY = copyrightY + copyrightHeight + footerSpacing
    let subtitleY = linkY + linkHeight + lineSpacing
    let versionY = subtitleY + lineHeight + lineSpacing
    let titleY = versionY + lineHeight + lineSpacing
    let iconY = titleY + titleHeight + titleSpacing

    let views: [(NSView, NSRect)] = [
      (
        {
          let v = NSImageView()
          v.image = NSApp.applicationIconImage
          v.imageScaling = .scaleProportionallyDown
          return v
        }(),
        NSRect(x: (windowWidth - iconSize) / 2, y: iconY, width: iconSize, height: iconSize)
      ),

      (
        {
          let f = NSTextField(labelWithString: "PingPlace")
          f.alignment = .center
          f.font = .boldSystemFont(ofSize: 16)
          return f
        }(),
        NSRect(x: horizontalPadding, y: titleY, width: contentWidth, height: titleHeight)
      ),

      (
        {
          let f = NSTextField(labelWithString: "Version \(version)")
          f.alignment = .center
          return f
        }(),
        NSRect(x: horizontalPadding, y: versionY, width: contentWidth, height: lineHeight)
      ),

      (
        {
          let f = NSTextField(labelWithString: "Made with <3")
          f.alignment = .center
          return f
        }(),
        NSRect(x: horizontalPadding, y: subtitleY, width: contentWidth, height: lineHeight)
      ),

      (
        {
          let b = NSButton()
          b.title = "@WadeGrimridge"
          b.bezelStyle = .inline
          b.isBordered = false
          b.target = self
          b.action = #selector(openTwitter)
          b.attributedTitle = NSAttributedString(
            string: "@WadeGrimridge",
            attributes: [
              .foregroundColor: NSColor.linkColor,
              .underlineStyle: NSUnderlineStyle.single.rawValue,
            ])
          return b
        }(),
        NSRect(x: horizontalPadding, y: linkY, width: contentWidth, height: linkHeight)
      ),

      (
        {
          let f = NSTextField(labelWithString: copyright)
          f.alignment = .center
          f.font = .systemFont(ofSize: 10)
          f.textColor = .secondaryLabelColor
          return f
        }(),
        NSRect(x: horizontalPadding, y: copyrightY, width: contentWidth, height: copyrightHeight)
      ),
    ]

    for (view, frame) in views {
      view.frame = frame
      content.addSubview(view)
    }

    win.contentView = content
    win.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc private func quitApp() {
    NSApp.terminate(nil)
  }

  @objc private func openTwitter() {
    NSWorkspace.shared.open(URL(string: "https://x.com/WadeGrimridge")!)
  }

  // MARK: NSWindowDelegate

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    sender.orderOut(nil)
    return false
  }

  private func info(_ message: String) {
    log(.info, message)
  }

  private func debug(_ message: String) {
    guard isDebugLoggingEnabled else { return }
    log(.debug, message)
  }

  private func error(_ message: String) {
    log(.error, message)
  }

  private func prepareLogFile() {
    let directoryURL = logFileURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: logFileURL.path) {
      FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
    }
  }

  private func log(_ level: LogLevel, _ message: String) {
    switch level {
    case .info:
      logger.info("\(message, privacy: .public)")
    case .debug:
      logger.debug("\(message, privacy: .public)")
    case .error:
      logger.error("\(message, privacy: .public)")
    }

    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(level.rawValue)] \(timestamp) \(message)\n"
    let data = Data(line.utf8)
    guard let fileHandle = try? FileHandle(forWritingTo: logFileURL) else { return }
    defer { try? fileHandle.close() }
    _ = try? fileHandle.seekToEnd()
    try? fileHandle.write(contentsOf: data)
  }
}

@main
enum PingPlaceMain {
  static func main() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    delegate.launch()
    app.run()
  }
}
