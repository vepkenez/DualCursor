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
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown]
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
        guard enabled else { return Unmanaged.passUnretained(event) }

        let now = ProcessInfo.processInfo.systemUptime
        guard let src = currentSource(now: now), src.key != activeKey else {
            return Unmanaged.passUnretained(event)
        }

        // Remember where the previous device left the cursor (before this event's delta).
        if let old = activeKey {
            var p = event.location
            if type == .mouseMoved {
                p.x -= CGFloat(event.getIntegerValueField(.mouseEventDeltaX))
                p.y -= CGFloat(event.getIntegerValueField(.mouseEventDeltaY))
            }
            saved[old] = p
        }

        let previous = activeName ?? "none"
        activeKey = src.key

        if let target = saved[src.key], isOnScreen(target) {
            event.location = target
            CGWarpMouseCursorPosition(target)
            CGAssociateMouseAndMouseCursorPosition(1)  // no post-warp freeze
            log("switch \(previous) -> \(src.name): restored (\(Int(target.x)), \(Int(target.y)))")
        } else {
            log("switch \(previous) -> \(src.name): first use, keeping cursor where it is")
        }
        onChange?()
        return Unmanaged.passUnretained(event)
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
