import AppKit
import ApplicationServices
import Foundation

private func finderAXCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let provider = Unmanaged<FinderAccessibilityProvider>.fromOpaque(refcon).takeUnretainedValue()
    provider.handleAXEvent(element: element, notification: notification as String)
}

public final class FinderAccessibilityProvider: TransferProvider {
    public let name = "Finder Accessibility fallback"
    public weak var delegate: TransferProviderDelegate?
    public private(set) var diagnostic = "Not started"

    private struct ObservedIndicator {
        let element: AXUIElement
        let startedAt: Date
        var lastFraction: Double?
    }

    private var observer: AXObserver?
    private var finderElement: AXUIElement?
    private var indicators: [String: ObservedIndicator] = [:]
    private var enabled = false

    public init(enabled: Bool) { self.enabled = enabled }

    public static var isPermissionGranted: Bool { AXIsProcessTrusted() }

    public func start(volumes: [Volume]) {
        guard enabled else {
            diagnostic = "Disabled. Enable the Finder Accessibility fallback in plugin settings if Foundation Progress is insufficient."
            return
        }
        guard Self.isPermissionGranted else {
            diagnostic = "Accessibility permission is not granted. Transfer Center will continue with Foundation Progress and FSEvents."
            Logger.shared.warning(diagnostic)
            return
        }
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            diagnostic = "Finder is not running."
            return
        }

        var createdObserver: AXObserver?
        let result = AXObserverCreate(finder.processIdentifier, finderAXCallback, &createdObserver)
        guard result == .success, let createdObserver else {
            diagnostic = "Unable to create an Accessibility observer for Finder (AX error \(result.rawValue))."
            return
        }

        let application = AXUIElementCreateApplication(finder.processIdentifier)
        let context = Unmanaged.passUnretained(self).toOpaque()
        _ = AXObserverAddNotification(createdObserver, application, kAXWindowCreatedNotification as CFString, context)
        observer = createdObserver
        finderElement = application
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(createdObserver), .commonModes)
        diagnostic = "Active. Finder progress indicators are observed without reading file contents."
        scanFinderWindows()
    }

    public func update(volumes: [Volume]) {}

    public func stop() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        finderElement = nil
        indicators.removeAll()
    }

    func handleAXEvent(element: AXUIElement, notification: String) {
        if notification == (kAXWindowCreatedNotification as String) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.scan(element, depth: 0, visited: 0) }
            return
        }
        let id = indicatorID(element)
        if notification == (kAXUIElementDestroyedNotification as String) {
            if let observed = indicators.removeValue(forKey: id) {
                let finalState: TransferState = (observed.lastFraction ?? 0) >= 0.999 ? .completed : .cancelled
                delegate?.transferProvider(self, emitted: .removed(id: id, finalState: finalState))
            }
            return
        }
        emitIndicator(element)
    }

    private func scanFinderWindows() {
        guard let finderElement else { return }
        for window in elements(finderElement, attribute: kAXWindowsAttribute) {
            scan(window, depth: 0, visited: 0)
        }
    }

    private func scan(_ element: AXUIElement, depth: Int, visited: Int) {
        guard depth <= 8, visited < 160 else { return }
        if stringValue(element, attribute: kAXRoleAttribute) == (kAXProgressIndicatorRole as String) {
            observeIndicator(element)
            return
        }
        var nextVisited = visited + 1
        for child in elements(element, attribute: kAXChildrenAttribute) {
            guard nextVisited < 160 else { break }
            scan(child, depth: depth + 1, visited: nextVisited)
            nextVisited += 1
        }
    }

    private func observeIndicator(_ element: AXUIElement) {
        let id = indicatorID(element)
        guard indicators[id] == nil else { return }
        indicators[id] = ObservedIndicator(element: element, startedAt: Date(), lastFraction: nil)
        if let observer {
            let context = Unmanaged.passUnretained(self).toOpaque()
            _ = AXObserverAddNotification(observer, element, kAXValueChangedNotification as CFString, context)
            _ = AXObserverAddNotification(observer, element, kAXUIElementDestroyedNotification as CFString, context)
        }
        emitIndicator(element)
    }

    private func emitIndicator(_ element: AXUIElement) {
        let id = indicatorID(element)
        guard var observed = indicators[id] else { return }
        let value = numberValue(element, attribute: kAXValueAttribute)
        let minimum = numberValue(element, attribute: kAXMinValueAttribute) ?? 0
        let maximum = numberValue(element, attribute: kAXMaxValueAttribute) ?? 1
        let fraction: Double? = {
            guard let value, maximum > minimum else { return nil }
            return min(1, max(0, (value - minimum) / (maximum - minimum)))
        }()
        observed.lastFraction = fraction
        indicators[id] = observed

        let title = nearestWindowTitle(from: element) ?? "Finder transfer"
        let transfer = Transfer(
            id: id,
            kind: .copying,
            state: fraction == nil ? .indeterminate : .active,
            displayName: title,
            fractionCompleted: fraction,
            startedAt: observed.startedAt,
            updatedAt: Date(),
            provider: .finderAccessibility,
            confidence: .inferred
        )
        delegate?.transferProvider(self, emitted: .updated(transfer))
    }

    private func nearestWindowTitle(from element: AXUIElement) -> String? {
        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let node = current else { break }
            if stringValue(node, attribute: kAXRoleAttribute) == (kAXWindowRole as String),
               let title = stringValue(node, attribute: kAXTitleAttribute), !title.isEmpty {
                return title
            }
            current = elementValue(node, attribute: kAXParentAttribute)
        }
        return nil
    }

    private func indicatorID(_ element: AXUIElement) -> String { "finder-ax-\(CFHash(element))" }

    private func elements(_ element: AXUIElement, attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func elementValue(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value.map { unsafeBitCast($0, to: AXUIElement.self) }
    }

    private func stringValue(_ element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func numberValue(_ element: AXUIElement, attribute: String) -> Double? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.doubleValue
    }

    deinit { stop() }
}
