// DualCursor — gives each pointing device (trackpad, mouse, …) its own remembered cursor
// position. When you switch devices, the cursor jumps back to where that device left it.
//
// How it works:
//   * IOHIDManager watches raw HID input, so we know *which* device just produced activity
//     (normal CGEvents don't say which device moved the pointer).
//   * A CGEvent tap sees each pointer move / click. If the device that caused it isn't the
//     one we last saw, we save the cursor position for the old device and warp the cursor to
//     the new device's saved position.
//
// Needs: Input Monitoring (for IOHIDManager) and Accessibility (for the event tap).
// Run `DualCursor.app/Contents/MacOS/DualCursor --log` from a terminal to see what it detects.

import Cocoa
import IOKit.hid
import ServiceManagement

let verbose = CommandLine.arguments.contains("--log")
func log(_ s: @autoclosure () -> String) {
    if verbose { print(s()) }
}

final class Device {
    let key: String
    let name: String
    var lastMotion: TimeInterval = 0   // relative X/Y movement or a button press
    var lastTouch: TimeInterval = 0    // touch-surface activity (absolute X/Y, digitizer)
    init(key: String, name: String) { self.key = key; self.name = name }
}

final class DualCursor {
    var devices: [String: Device] = [:]
    var saved: [String: CGPoint] = [:]
    var activeKey: String?
    var enabled = true
    var tap: CFMachPort?
    var hid: IOHIDManager?
    var onChange: (() -> Void)?
    var lastLocation: CGPoint?   // where the previous pointer event put the cursor

    // How recent HID activity must be to be attributed to a pointer event.
    let motionWindow: TimeInterval = 0.10
    let touchWindow: TimeInterval = 0.25

    var activeName: String? { activeKey.flatMap { devices[$0]?.name } }

    // MARK: HID

    func startHID() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Int]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Pointer],
            [kIOHIDDeviceUsagePageKey: kHIDPage_Digitizer, kIOHIDDeviceUsageKey: kHIDUsage_Dig_TouchPad],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { ctx, _, _, value in
            Unmanaged<DualCursor>.fromOpaque(ctx!).takeUnretainedValue().handleHID(value)
        }, ctx)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            let me = Unmanaged<DualCursor>.fromOpaque(ctx!).takeUnretainedValue()
            let d = me.device(for: device)
            log("device attached: \(d.name) [\(d.key)]")
            me.onChange?()
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        log("IOHIDManagerOpen -> \(result == kIOReturnSuccess ? "ok" : String(format: "0x%08x", result))")
        hid = manager
    }

    private func prop(_ d: IOHIDDevice, _ key: String) -> Any? {
        IOHIDDeviceGetProperty(d, key as CFString)
    }

    /// One logical device per vendor/product/name, so a trackpad's several HID interfaces
    /// (mouse-compatible + digitizer) count as the same device.
    func device(for d: IOHIDDevice) -> Device {
        let vendor = prop(d, kIOHIDVendorIDKey) as? Int ?? 0
        let product = prop(d, kIOHIDProductIDKey) as? Int ?? 0
        let name = prop(d, kIOHIDProductKey) as? String ?? "Unknown device"
        let key = "\(vendor):\(product):\(name)"
        if let existing = devices[key] { return existing }
        let dev = Device(key: key, name: name)
        devices[key] = dev
        return dev
    }

    func handleHID(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let page = Int(IOHIDElementGetUsagePage(element))
        let usage = Int(IOHIDElementGetUsage(element))
        let v = IOHIDValueGetIntegerValue(value)
        let dev = device(for: IOHIDElementGetDevice(element))
        let now = ProcessInfo.processInfo.systemUptime

        switch page {
        case kHIDPage_GenericDesktop where usage == kHIDUsage_GD_X || usage == kHIDUsage_GD_Y:
            if IOHIDElementIsRelative(element) {
                if v != 0 { dev.lastMotion = now }
            } else {
                dev.lastTouch = now
            }
        case kHIDPage_Button:
            if v != 0 { dev.lastMotion = now }
        case kHIDPage_Digitizer:
            dev.lastTouch = now
        default:
            break
        }
    }

    /// The device most likely responsible for a pointer event happening now.
    /// Real relative motion / button presses win over mere touch-surface contact, so a palm
    /// resting on the trackpad doesn't steal the cursor while you use the mouse.
    func currentSource(now: TimeInterval) -> Device? {
        if let m = devices.values.filter({ now - $0.lastMotion < motionWindow })
            .max(by: { $0.lastMotion < $1.lastMotion }) {
            return m
        }
        return devices.values.filter({ now - $0.lastTouch < touchWindow })
            .max(by: { $0.lastTouch < $1.lastTouch })
    }

    // MARK: Event tap

    @discardableResult
    func startTap() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, ctx in
                Unmanaged<DualCursor>.fromOpaque(ctx!).takeUnretainedValue().handleEvent(type, event)
            },
            userInfo: ctx)
        else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        log("event tap started")
        return true
    }

    func handleEvent(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard enabled, !isPausedForFrontmostApp() else { return Unmanaged.passUnretained(event) }

        let isMove = type == .mouseMoved || type == .leftMouseDragged
            || type == .rightMouseDragged || type == .otherMouseDragged
        let dx = isMove ? event.getIntegerValueField(.mouseEventDeltaX) : 0
        let dy = isMove ? event.getIntegerValueField(.mouseEventDeltaY) : 0
        let location = event.location
        var seenAt = location
        defer { lastLocation = seenAt }

        // A game in mouselook detaches the cursor from the mouse: deltas keep coming while the
        // location stays put. Warping (and re-associating) then would break its camera control,
        // so leave the switch for later, once the cursor moves freely again.
        let locked = (dx != 0 || dy != 0) && lastLocation == location

        let now = ProcessInfo.processInfo.systemUptime
        guard !locked, let src = currentSource(now: now), src.key != activeKey else {
            return Unmanaged.passUnretained(event)
        }

        // Where the cursor was before this event's delta: the previous device's spot.
        let before = CGPoint(x: location.x - CGFloat(dx), y: location.y - CGFloat(dy))
        if let old = activeKey { saved[old] = before }

        let previous = activeName ?? "none"
        activeKey = src.key
        defer { onChange?() }

        // Mid-drag, a jump would drag whatever is being held (or spin a game camera): just
        // hand the cursor over where it is.
        let dragging = type == .leftMouseDragged || type == .rightMouseDragged
            || type == .otherMouseDragged
        guard !dragging, let target = saved[src.key], isOnScreen(target) else {
            log("switch \(previous) -> \(src.name): keeping cursor where it is")
            return Unmanaged.passUnretained(event)
        }

        event.location = target
        // Games that draw their own cursor (World of Warcraft, …) move it by adding up deltas
        // and never see a warp, so make the jump part of this event's delta as well.
        if isMove {
            event.setIntegerValueField(.mouseEventDeltaX, value: Int64((target.x - before.x).rounded()))
            event.setIntegerValueField(.mouseEventDeltaY, value: Int64((target.y - before.y).rounded()))
        }
        CGWarpMouseCursorPosition(target)
        CGAssociateMouseAndMouseCursorPosition(1)  // no post-warp freeze
        seenAt = target
        log("switch \(previous) -> \(src.name): restored (\(Int(target.x)), \(Int(target.y)))")
        return Unmanaged.passUnretained(event)
    }

    // MARK: Paused apps

    static let pausedAppsKey = "pausedBundleIDs"
    var pausedBundleIDs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: pausedAppsKey) ?? []) {
        didSet { UserDefaults.standard.set(pausedBundleIDs.sorted(), forKey: Self.pausedAppsKey) }
    }
    var frontmostBundleID: String? = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

    func isPausedForFrontmostApp() -> Bool {
        guard let id = frontmostBundleID else { return false }
        return pausedBundleIDs.contains(id)
    }

    func watchFrontmostApp() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.frontmostBundleID = app?.bundleIdentifier
        }
    }

    func isOnScreen(_ p: CGPoint) -> Bool {
        var count: UInt32 = 0
        CGGetDisplaysWithPoint(p, 0, nil, &count)
        return count > 0
    }

    func forgetPositions() {
        saved.removeAll()
        onChange?()
    }
}

// MARK: Menu bar app

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let dc = DualCursor()
    var item: NSStatusItem!
    var retryTimer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "DualCursor")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        // Ask for both permissions up front (each shows a system prompt the first time).
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)

        dc.watchFrontmostApp()
        dc.startHID()
        if !dc.startTap() {
            log("event tap not available yet (grant Accessibility); retrying every 2s")
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                guard let self else { return }
                if self.dc.startTap() {
                    t.invalidate()
                    // HID access may also just have been granted; reopen to be safe.
                    if let hid = self.dc.hid { IOHIDManagerClose(hid, IOOptionBits(kIOHIDOptionsTypeNone)) }
                    self.dc.startHID()
                }
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let hidOK = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        let axOK = AXIsProcessTrusted()
        if !hidOK || !axOK {
            let missing = [hidOK ? nil : "Input Monitoring", axOK ? nil : "Accessibility"].compactMap { $0 }
            menu.addItem(disabled("⚠︎ Needs: \(missing.joined(separator: ", "))"))
            menu.addItem(withTitle: "Open Privacy Settings…", action: #selector(openPrivacy), keyEquivalent: "")
                .target = self
            menu.addItem(.separator())
        }

        menu.addItem(disabled("Active: \(dc.activeName ?? "—")"))
        let names = dc.devices.values.map(\.name).sorted()
        if !names.isEmpty {
            menu.addItem(disabled("Devices:"))
            for d in dc.devices.values.sorted(by: { $0.name < $1.name }) {
                let mark = dc.saved[d.key] != nil ? "  • " : "    "
                menu.addItem(disabled(mark + d.name))
            }
        }
        menu.addItem(.separator())

        let toggle = menu.addItem(withTitle: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = dc.enabled ? .on : .off

        menu.addItem(pauseMenu())

        menu.addItem(withTitle: "Forget Saved Positions", action: #selector(forget), keyEquivalent: "").target = self

        let login = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit DualCursor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    /// "Pause In" submenu: running apps (plus any already paused) — DualCursor stays out of the
    /// way while a checked app is frontmost. For games that read the mouse in their own way.
    private func pauseMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Pause In", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        var names: [String: String] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier {
                names[id] = app.localizedName ?? id
            }
        }
        for id in dc.pausedBundleIDs where names[id] == nil {
            names[id] = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                .map { FileManager.default.displayName(atPath: $0.path) } ?? id
        }
        for (id, name) in names.sorted(by: { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }) {
            let i = sub.addItem(withTitle: name, action: #selector(togglePaused(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = id
            i.state = dc.pausedBundleIDs.contains(id) ? .on : .off
        }
        parent.submenu = sub
        if !dc.pausedBundleIDs.isEmpty { parent.title = "Pause In (\(dc.pausedBundleIDs.count))" }
        return parent
    }

    @objc func togglePaused(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if dc.pausedBundleIDs.contains(id) { dc.pausedBundleIDs.remove(id) } else { dc.pausedBundleIDs.insert(id) }
    }

    @objc func toggleEnabled() { dc.enabled.toggle() }
    @objc func forget() { dc.forgetPositions() }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    @objc func openPrivacy() {
        let pane = AXIsProcessTrusted() ? "Privacy_ListenEvent" : "Privacy_Accessibility"
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}

setvbuf(stdout, nil, _IONBF, 0)
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
