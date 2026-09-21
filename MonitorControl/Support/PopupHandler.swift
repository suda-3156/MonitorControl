//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Cocoa
import os.log

// The centre popup: the sliders of the display a key press just went to, shown in the
// middle of that display. It shares its sliders with the menu, so both show the same value
// and write through the same path (see SliderHandler). It never takes focus and never
// reads DDC: what it shows is what the app already holds.
class PopupHandler {
  private let sliderWidth: CGFloat = 220
  private let margin: CGFloat = 13
  private let visibleSeconds: TimeInterval = 1.5
  private let pointerInsideSeconds: TimeInterval = 0.5
  private let escapeKeyCode: UInt16 = 53

  private var panel: NSPanel?
  private var screenDisplayID: CGDirectDisplayID = 0
  private var attached: [(handler: SliderHandler, sliderView: SliderHandler.SliderView)] = []
  private var hideTimer: Timer?
  private var monitors: [Any] = []

  // Entry point from OSDUtils: for a display this app drives itself, the popup takes the
  // place of the system HUD. Returning true means the HUD is not shown. showOsd is also
  // called off the main thread (the sw brightness animation), hence the dispatch below:
  // only the window work has to be on the main thread.
  func handleOsd(displayID: CGDirectDisplayID, command: Command) -> Bool {
    guard !app.safeMode, let display = DisplayManager.shared.getAllDisplays().first(where: { $0.identifier == displayID }) else {
      return false
    }
    let isCombined = prefs.integer(forKey: PrefKey.multiSliders.rawValue) == MultiSliders.combine.rawValue
    guard let otherDisplay = display as? OtherDisplay, !otherDisplay.isDummy else {
      // In combine mode the value is written to every display, so an Apple display would
      // put a system HUD next to the popup that the other displays already show.
      return isCombined && (display.sliderHandler[command]?.displays.contains { $0 is OtherDisplay } ?? false)
    }
    let wanted: [Command]
    switch command {
    case .audioSpeakerVolume, .audioMuteScreenBlank:
      guard !otherDisplay.isSw() else {
        return false
      }
      wanted = [.audioSpeakerVolume]
    case .brightness, .contrast:
      // Contrast exists only over DDC, so a software controlled display gets one slider.
      wanted = otherDisplay.isSw() ? [.brightness] : [.brightness, .contrast]
    default:
      return false
    }
    let commands = wanted.filter { display.sliderHandler[$0] != nil }
    guard !commands.isEmpty else {
      return false
    }
    guard !display.readPrefAsBool(key: .hideOsd) else {
      return true // the display is set to show nothing at all
    }
    // In combine mode one popup stands for every display, so it goes where the cursor is.
    var screenDisplayID = display.identifier
    if isCombined, let currentDisplay = DisplayManager.shared.getCurrentDisplay() {
      screenDisplayID = currentDisplay.identifier
    }
    DispatchQueue.main.async {
      self.show(display: display, commands: commands, screenDisplayID: screenDisplayID)
    }
    return true
  }

  func show(display: Display, commands: [Command], screenDisplayID: CGDirectDisplayID) {
    let handlers = commands.compactMap { display.sliderHandler[$0] }
    guard !handlers.isEmpty, let screen = DisplayManager.getByDisplayID(displayID: screenDisplayID) else {
      return
    }
    if self.panel != nil, self.screenDisplayID == screenDisplayID, self.attached.count == handlers.count, !zip(self.attached, handlers).contains(where: { $0.handler !== $1 }) {
      // A key held down keeps pushing values into the sliders that are already up, so only
      // the countdown starts over.
      self.startHideTimer()
      return
    }
    self.hide()
    var sliderViews: [SliderHandler.SliderView] = []
    for handler in handlers {
      let sliderView = handler.makeSliderView(width: self.sliderWidth, tint: NSColor.labelColor.withAlphaComponent(0.7))
      self.attached.append((handler: handler, sliderView: sliderView))
      sliderViews.append(sliderView)
    }
    var contentWidth: CGFloat = 0
    var contentHeight: CGFloat = 0
    for sliderView in sliderViews {
      contentWidth = max(sliderView.view.frame.width, contentWidth)
      contentHeight += sliderView.view.frame.height
    }
    let frame = NSRect(x: 0, y: 0, width: contentWidth + self.margin * 2, height: contentHeight + self.margin * 2)
    let panel = self.makePanel(frame: frame)
    var sliderPosition = self.margin + contentHeight
    for sliderView in sliderViews {
      sliderPosition -= sliderView.view.frame.height
      sliderView.view.setFrameOrigin(NSPoint(x: self.margin, y: sliderPosition))
      panel.contentView?.addSubview(sliderView.view)
    }
    panel.setFrameOrigin(NSPoint(x: screen.frame.midX - frame.width / 2, y: screen.frame.midY - frame.height / 2))
    panel.orderFrontRegardless() // never makeKeyAndOrderFront: the popup must not take focus
    self.panel = panel
    self.screenDisplayID = screenDisplayID
    self.startMonitoring()
    self.startHideTimer()
    os_log("Popup shown on display %{public}@", type: .info, String(screenDisplayID))
  }

  func hide() {
    self.hideTimer?.invalidate()
    self.hideTimer = nil
    for monitor in self.monitors {
      NSEvent.removeMonitor(monitor)
    }
    self.monitors = []
    for attached in self.attached {
      attached.handler.removeSliderView(attached.sliderView)
    }
    self.attached = []
    guard let panel = self.panel else {
      return
    }
    panel.orderOut(nil)
    panel.close()
    self.panel = nil
    self.screenDisplayID = 0
    os_log("Popup hidden", type: .info)
  }

  private func makePanel(frame: NSRect) -> NSPanel {
    // A nonactivating panel takes mouse events without the app becoming active, and a
    // borderless one never becomes the key window, so the sliders keep working while the
    // frontmost app stays where it is. MCSlider.acceptsFirstMouse does the rest.
    let panel = NSPanel(contentRect: frame, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
    panel.title = "Monitor Control Popup"
    panel.isFloatingPanel = true
    panel.becomesKeyOnlyIfNeeded = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.isMovableByWindowBackground = false
    panel.animationBehavior = .none
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
    panel.collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
    let background = NSVisualEffectView(frame: frame)
    background.material = .hudWindow
    background.blendingMode = .behindWindow
    background.state = .active
    background.wantsLayer = true
    background.layer?.cornerRadius = 12
    background.layer?.masksToBounds = true
    panel.contentView = background
    return panel
  }

  private func startHideTimer(_ seconds: TimeInterval? = nil) {
    self.hideTimer?.invalidate()
    self.hideTimer = Timer.scheduledTimer(withTimeInterval: seconds ?? self.visibleSeconds, repeats: false) { [weak self] _ in
      guard let self = self else {
        return
      }
      // Never pull the popup out from under the pointer.
      if let panel = self.panel, panel.frame.contains(NSEvent.mouseLocation) {
        self.startHideTimer(self.pointerInsideSeconds)
        return
      }
      self.hide()
    }
  }

  // The panel is never the key window, so Escape and clicks elsewhere only arrive through
  // event monitors. Accessibility is already required for the media keys, and the global
  // monitors need nothing beyond it.
  private func startMonitoring() {
    let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents, handler: { [weak self] _ in self?.hide() }) {
      self.monitors.append(monitor)
    }
    if let monitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents, handler: { [weak self] event in
      if event.window === self?.panel {
        self?.startHideTimer()
      } else {
        self?.hide()
      }
      return event
    }) {
      self.monitors.append(monitor)
    }
    if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
      guard let self = self, event.keyCode == self.escapeKeyCode else {
        return
      }
      self.hide()
    }) {
      self.monitors.append(monitor)
    }
    if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
      if let self = self, event.keyCode == self.escapeKeyCode {
        self.hide()
        return nil
      }
      return event
    }) {
      self.monitors.append(monitor)
    }
  }
}
