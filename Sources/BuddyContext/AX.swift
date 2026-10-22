import ApplicationServices

/// Typed reads over the synchronous AX C API. Safe from any thread; each call is a message to
/// the target app, bounded by the messaging timeout.
enum AX {
    /// Measured in S1 (macOS 26.6, n=5): the default timeout is about 1.5 s; 0.25 s set on the
    /// system-wide element applies to every element the process creates.
    static let messagingTimeout: Float = 0.25

    static func setProcessTimeout() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout)
    }

    static func value(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success ? value : nil
    }

    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = value(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        guard let v = value(el, attr), CFGetTypeID(v) == CFStringGetTypeID() else { return nil }
        let s = (v as! CFString) as String
        return s.isEmpty ? nil : s
    }

    static func axValue<T: BitwiseCopyable>(_ v: CFTypeRef?, _ type: AXValueType, _ empty: T) -> T? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        let axv = v as! AXValue
        guard AXValueGetType(axv) == type else { return nil }
        var out = empty
        return AXValueGetValue(axv, type, &out) ? out : nil
    }

    static func range(_ el: AXUIElement, _ attr: String) -> CFRange? {
        axValue(value(el, attr), .cfRange, CFRange())
    }

    static func point(_ el: AXUIElement, _ attr: String) -> CGPoint? {
        axValue(value(el, attr), .cgPoint, CGPoint.zero)
    }

    static func size(_ el: AXUIElement, _ attr: String) -> CGSize? {
        axValue(value(el, attr), .cgSize, CGSize.zero)
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = point(el, kAXPositionAttribute), let s = size(el, kAXSizeAttribute) else { return nil }
        return CGRect(origin: p, size: s)
    }

    static func boundsForRange(_ el: AXUIElement, _ range: CFRange) -> CGRect? {
        var r = range
        guard let param = AXValueCreate(.cfRange, &r) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            el, kAXBoundsForRangeParameterizedAttribute as CFString, param, &out) == .success
        else { return nil }
        return axValue(out, .cgRect, CGRect.zero)
    }

    /// WebKit and Chromium text-marker path (AXWebConstants.h).
    static func boundsForSelectedTextMarker(_ el: AXUIElement) -> CGRect? {
        guard let marker = value(el, kAXSelectedTextMarkerRangeAttribute),
              CFGetTypeID(marker) == AXTextMarkerRangeGetTypeID() else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            el, kAXBoundsForTextMarkerRangeParameterizedAttribute as CFString, marker, &out) == .success
        else { return nil }
        return axValue(out, .cgRect, CGRect.zero)
    }

    /// The selected text through its text-marker range (WebKit and Chromium web areas).
    static func selectedTextViaMarker(_ el: AXUIElement) -> String? {
        if let text = string(el, kAXSelectedTextAttribute), !text.isEmpty { return text }
        guard let marker = value(el, kAXSelectedTextMarkerRangeAttribute),
              CFGetTypeID(marker) == AXTextMarkerRangeGetTypeID() else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            el, "AXStringForTextMarkerRange" as CFString, marker, &out) == .success else { return nil }
        return out as? String
    }

    static func isSecure(_ el: AXUIElement) -> Bool {
        isSecure(el, role: string(el, kAXRoleAttribute))
    }

    /// When the caller has already read the role.
    static func isSecure(_ el: AXUIElement, role: String?) -> Bool {
        role == "AXSecureTextField" || string(el, kAXSubroleAttribute) == kAXSecureTextFieldSubrole
    }

    static func pid(_ el: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(el, &pid) == .success ? pid : nil
    }
}
