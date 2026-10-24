//
//  ESDockKitBridge.swift
//  TakeCast
//
//  The only Swift file in the project, and it exists under protest. DockKit
//  has no Objective-C surface at all: setSystemTrackingEnabled is async, and
//  state, battery, and accessory events arrive as AsyncSequences. A shim is
//  the only way in.
//
//  Everything DockKit is confined to this file. It turns the framework into
//  one delegate that ESMainViewController consumes like ESCaptureEngine or
//  either governor, so no other class imports DockKit or knows it exists.
//
//  DockKit ships in the device SDK only, so every call is behind canImport.
//  On the simulator this class compiles to a bridge that never docks, which
//  keeps the synthetic buffer harness and UI layout work building there.
//
//  All entry points and all delegate callbacks are main queue. Call it from
//  the main thread only.
//

import Foundation
import UIKit

#if canImport(DockKit)
import DockKit
#endif

/// One physical press arrives as more than one shutter event. Apple's DockKit
/// sample debounces at 0.2 s, so the duplicate is expected behaviour rather
/// than a quirk of one gimbal, but measured against this hardware 0.2 s is too
/// tight: the Flow 2 Pro's duplicate has been seen at 0.181 s, which leaves
/// 19 ms of margin on a Bluetooth accessory. 0.4 s keeps better than twice the
/// worst observed gap while still letting an operator who started a recording
/// by accident stop it again inside half a second. Every accepted press logs
/// the gap since the last, so a duplicate that ever lands outside the window
/// is a line in the log rather than a recording that stopped itself.
private let ESDockKitShutterDebounce: TimeInterval = 0.4

@objc public protocol ESDockKitBridgeDelegate: NSObjectProtocol {
    @objc optional func dockKitBridgeDidChangeDockedState(_ bridge: ESDockKitBridge)
    @objc optional func dockKitBridgeDidUpdateBattery(_ bridge: ESDockKitBridge)

    // Fires only once the gimbal has actually accepted the change, so the HUD
    // never claims a frame is held before it is.
    @objc optional func dockKitBridgeDidChangeTrackingState(_ bridge: ESDockKitBridge)

    // The gimbal handle acts as a REC remote: shutter button or any hardware
    // button, delivered once per press, never on release.
    @objc optional func dockKitBridgeDidPressShutter(_ bridge: ESDockKitBridge)

    // An absolute zoom factor from the gimbal rocker. Unclamped; the receiver
    // owns the legal range.
    @objc optional func dockKitBridge(_ bridge: ESDockKitBridge,
                                      didRequestZoomFactor factor: CGFloat)

    // For the HUD and the instrument log.
    @objc optional func dockKitBridge(_ bridge: ESDockKitBridge,
                                      didReportMessage message: String)

    // Every raw accessory event, verbatim, for the instrument log only. This
    // is what a gimbal actually emits as opposed to what we assume it emits.
    // Never route this to the HUD; a wheel produces a torrent.
    @objc optional func dockKitBridge(_ bridge: ESDockKitBridge,
                                      didTraceEvent text: String)
}

@objc(ESDockKitBridge)
@MainActor
public final class ESDockKitBridge: NSObject {

    @objc public weak var delegate: ESDockKitBridgeDelegate?

    /// True while an iPhone is seated in a DockKit gimbal. Always false on the
    /// simulator, which cannot connect to an accessory.
    @objc public private(set) var docked = false

    /// Vendor model string, empty when nothing is docked.
    @objc public private(set) var accessoryName = ""

    /// Gimbal charge, 0.0 through 1.0. Negative means not reported.
    @objc public private(set) var batteryLevel: Double = -1
    @objc public private(set) var batteryCharging = false
    @objc public private(set) var batteryLow = false

    /// Mirrors DockKit. System tracking defaults to on for any docked camera
    /// app, which is exactly the behaviour a locked ceremony shot must not have.
    @objc public private(set) var systemTrackingEnabled = true

    @objc public override init() { super.init() }

    private var stateTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var batteryTask: Task<Void, Never>?
    private var lastShutter: Date?
    private var sawCameraShutter = false
    private var foregroundObserver: NSObjectProtocol?

    /// What the operator last asked for, whether by tapping LOCK or by pressing
    /// the gimbal's trigger. DockKit does not promise to keep the system
    /// tracking state across app launch, termination, or a trip through the
    /// background, so this is what gets restored when the app comes back,
    /// rather than whatever DockKit happens to have reset it to. Tracking
    /// intent, not observed state; systemTrackingEnabled is the observed one.
    private var intendedTracking: Bool?

    #if canImport(DockKit)
    private var accessory: DockAccessory?
    #endif

    // MARK: - Lifecycle

    /// Begins watching for dock and undock. Safe to call when no gimbal will
    /// ever appear: the app runs identically on a dumb tripod.
    @objc public func start() {
        #if canImport(DockKit)
        guard stateTask == nil else { return }

        // Apple is explicit that the system tracking state survives neither a
        // relaunch nor a trip through the background. Without this, a glance at
        // a notification mid ceremony is enough to hand the gimbal back to
        // system tracking while the HUD still reads HELD.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.restoreTrackingAfterForeground() }
        }

        stateTask = Task { [weak self] in
            do {
                for await change in try DockAccessoryManager.shared.accessoryStateChanges {
                    guard let self else { return }
                    self.handleStateChange(change)
                }
            } catch {
                self?.report("Dock accessory monitoring unavailable: \(error.localizedDescription)")
            }
        }
        #endif
    }

    @objc public func stop() {
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
            foregroundObserver = nil
        }
        stateTask?.cancel()
        stateTask = nil
        detachAccessory()
    }

    /// Puts back what the operator last asked for, because DockKit does not
    /// promise to carry the system tracking state through a trip to the
    /// background. Restores intent rather than imposing a policy, so a trigger
    /// press made before backgrounding survives coming back, and so does LOCK.
    ///
    /// Two deliberate restrictions, both learned the hard way. It does nothing
    /// unless a gimbal is docked and the operator has actually expressed an
    /// intent, so a plain launch adds no DockKit work at all: reading
    /// DockAccessoryManager at startup with nothing docked crashed inside
    /// DockKitCore, on a retain, from its own async completion. And it re-issues
    /// the same setTrackingEnabled call the LOCK button uses, which is proven on
    /// hardware, rather than reading isSystemTrackingEnabled back. Re-asserting
    /// a value that already holds is harmless.
    private func restoreTrackingAfterForeground() {
        #if canImport(DockKit)
        guard docked, let intended = intendedTracking else { return }
        trace("re-asserting tracking \(intended ? "on" : "off") on returning to the foreground")
        setTrackingEnabled(intended)
        #endif
    }

    // MARK: - Tracking

    /// The reason this bridge exists. A DockKit gimbal pans by itself under
    /// system tracking, which would walk a locked ceremony frame off the
    /// couple. Wire this to the LOCK control: locked means tracking off.
    ///
    /// Fire and forget. The result arrives as a message to the delegate so the
    /// operator sees on the HUD whether the gimbal actually obeyed.
    ///
    /// Named to avoid colliding with the Objective-C setter selector that the
    /// systemTrackingEnabled property would otherwise claim.
    @objc public func setTrackingEnabled(_ enabled: Bool) {
        #if canImport(DockKit)
        intendedTracking = enabled
        Task { [weak self] in
            do {
                try await DockAccessoryManager.shared.setSystemTrackingEnabled(enabled)
                guard let self else { return }
                self.systemTrackingEnabled = enabled
                self.delegate?.dockKitBridgeDidChangeTrackingState?(self)
                if self.docked {
                    self.report(enabled ? "Gimbal tracking on" : "Gimbal tracking off, frame is held")
                }
            } catch {
                // Worth shouting about: the operator believes the frame is
                // locked and the gimbal is still free to move.
                self?.report("GIMBAL TRACKING \(enabled ? "ENABLE" : "DISABLE") FAILED: \(error.localizedDescription)")
            }
        }
        #endif
    }

    // MARK: - Accessory plumbing

    #if canImport(DockKit)

    private func handleStateChange(_ change: DockAccessory.StateChange) {
        let nowDocked = (change.state == .docked)

        if nowDocked, let accessory = change.accessory {
            attach(to: accessory)
        } else if !nowDocked {
            detachAccessory()
        }

        // DockKit raises a state change when a person presses the gimbal's
        // tracking button, not only on dock and undock. That button is an
        // operator control in its own right: it is how you lock onto the
        // couple for a walking shot. Adopt what it reports rather than
        // overriding it, so the HUD reports the gimbal's real state instead of
        // the last state we happened to command. Nothing else observes this,
        // and a lamp that reads HELD over a gimbal that is panning is worse
        // than no lamp.
        let isDockTransition = (docked != nowDocked)
        if systemTrackingEnabled != change.trackingButtonEnabled {
            systemTrackingEnabled = change.trackingButtonEnabled
            trace("tracking button now \(change.trackingButtonEnabled ? "on" : "off")")
            delegate?.dockKitBridgeDidChangeTrackingState?(self)
            // Announce a button press, but stay quiet when tracking merely came
            // up with a freshly docked accessory. A press is also the operator
            // stating an intent, so it becomes the thing restored after a trip
            // through the background.
            if !isDockTransition {
                intendedTracking = change.trackingButtonEnabled
                report(change.trackingButtonEnabled
                       ? "Gimbal tracking on, from the gimbal button"
                       : "Gimbal tracking off, from the gimbal button")
            }
        }

        guard docked != nowDocked else { return }
        docked = nowDocked
        report(nowDocked ? "Gimbal docked: \(accessoryName.isEmpty ? "unknown model" : accessoryName)"
                         : "Gimbal undocked")
        delegate?.dockKitBridgeDidChangeDockedState?(self)
    }

    private func attach(to accessory: DockAccessory) {
        detachAccessory()
        self.accessory = accessory
        accessoryName = accessory.hardwareModel ?? ""

        // Deliberately does not re-assert tracking here. Restoring it across a
        // re-dock is the view controller's call, on the docked-state callback,
        // because only it knows whether LOCK is engaged. Doing it here as well
        // would race the tracking button state arriving in the same event.

        eventTask = Task { [weak self] in
            do {
                for await event in try accessory.accessoryEvents {
                    guard let self else { return }
                    self.handleAccessoryEvent(event)
                }
            } catch {
                self?.report("Gimbal buttons unavailable: \(error.localizedDescription)")
            }
        }

        batteryTask = Task { [weak self] in
            do {
                for await state in try accessory.batteryStates {
                    guard let self else { return }
                    self.handleBatteryState(state)
                }
            } catch {
                self?.report("Gimbal battery unavailable: \(error.localizedDescription)")
            }
        }
    }

    private func handleAccessoryEvent(_ event: DockAccessory.AccessoryEvent) {
        switch event {
        case .cameraShutter:
            sawCameraShutter = true
            trace("shutter")
            deliverShutter()
        case .button(let id, let pressed):
            trace("button id=\(id) pressed=\(pressed ? 1 : 0)")
            // Raw buttons drive REC only on an accessory that has never
            // reported a semantic shutter. On one that has, its buttons are
            // other controls, a wheel or a mode key, and must not toggle a
            // recording. Mapping every id onto REC is how one press became a
            // start and an immediate stop. Either arrival order yields exactly
            // one toggle: whichever lands first wins, the debounce eats the
            // other.
            guard !sawCameraShutter, pressed else { return }
            deliverShutter()
        case .cameraZoom(let factor):
            trace(String(format: "zoom factor=%.4f", factor))
            delegate?.dockKitBridge?(self, didRequestZoomFactor: CGFloat(factor))
        case .cameraFlip:
            // Rear wide only. Say so rather than swallowing the press.
            trace("flip")
            report("Gimbal flip ignored, TakeCast is rear camera only")
        @unknown default:
            trace("unknown event")
        }
    }

    /// Collapses a burst into one REC toggle. Some accessories emit both a
    /// semantic shutter and a raw button for one physical press, and a toggle
    /// that fires twice starts and stops a recording in the same breath.
    private func deliverShutter() {
        let now = Date()
        if let last = lastShutter {
            let gap = now.timeIntervalSince(last)
            if gap < ESDockKitShutterDebounce {
                trace(String(format: "shutter ignored, %.3f s after the last", gap))
                return
            }
            // The margin between this and the debounce window is the evidence
            // that the window is wide enough. A gap barely over it means a
            // duplicate is landing outside and REC is about to toggle twice.
            trace(String(format: "shutter accepted, %.3f s after the last", gap))
        }
        lastShutter = now
        delegate?.dockKitBridgeDidPressShutter?(self)
    }

    private func handleBatteryState(_ state: DockAccessory.BatteryState) {
        batteryLevel = state.batteryLevel
        batteryCharging = (state.chargeState == .charging)
        let wasLow = batteryLow
        batteryLow = state.lowBattery
        if batteryLow && !wasLow {
            report("Gimbal battery low")
        }
        delegate?.dockKitBridgeDidUpdateBattery?(self)
    }

    #endif

    private func detachAccessory() {
        eventTask?.cancel()
        eventTask = nil
        batteryTask?.cancel()
        batteryTask = nil
        #if canImport(DockKit)
        accessory = nil
        #endif
        accessoryName = ""
        batteryLevel = -1
        batteryCharging = false
        batteryLow = false
    }

    /// One line for the HUD and the instrument log, for example
    /// "docked JOBY-1 82% held" or "none".
    @objc public var statusDescription: String {
        guard docked else { return "none" }
        var text = "docked"
        if !accessoryName.isEmpty { text += " \(accessoryName)" }
        if batteryLevel >= 0 {
            text += String(format: " %.0f%%", batteryLevel * 100)
            if batteryCharging { text += " charging" }
        }
        text += systemTrackingEnabled ? " tracking" : " held"
        return text
    }

    private func report(_ message: String) {
        delegate?.dockKitBridge?(self, didReportMessage: message)
    }

    private func trace(_ text: String) {
        delegate?.dockKitBridge?(self, didTraceEvent: text)
    }
}
