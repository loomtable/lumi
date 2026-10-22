import ApplicationServices
import BuddyCore
import CoreGraphics
import Foundation

public struct AXWindowSensor: WindowSensor {
    public init() {}

    public func window(pid: Int32) -> ContextPacket.Window? {
        let app = AXUIElementCreateApplication(pid)
        guard let win = AX.element(app, kAXFocusedWindowAttribute) else { return nil }
        let title = AX.string(win, kAXTitleAttribute)
        // AXDocument is a file URL string for document windows.
        let document = AX.string(win, kAXDocumentAttribute)
            .flatMap(URL.init(string:)).flatMap { $0.isFileURL ? $0.path : nil }
        let bounds = AX.frame(win).flatMap(Self.rect)
        guard title != nil || document != nil || bounds != nil else { return nil }
        return ContextPacket.Window(title: title, document: document, bounds: bounds)
    }

    /// Nil for an empty frame (a window still opening, or one AX can't place).
    static func rect(_ frame: CGRect) -> ContextPacket.Rect? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        return ContextPacket.Rect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
    }
}

public struct AXSelectionSensor: SelectionSensor {
    public init() {}

    public func selection(pid: Int32) -> ContextPacket.Selection? {
        let app = AXUIElementCreateApplication(pid)
        let focused = AX.element(app, kAXFocusedUIElementAttribute)
        let role = focused.flatMap { AX.string($0, kAXRoleAttribute) }
        if let el = focused {
            // A password field: nothing, and no looking around it either.
            guard !AX.isSecure(el, role: role) else { return nil }
            if let text = AX.string(el, kAXSelectedTextAttribute), !text.isEmpty {
                let (bounds, source) = Self.bounds(of: el)
                return ContextPacket.Selection(text: text, bounds: bounds, boundsSource: source)
            }
        }
        // A selection in web content that never takes focus (Safari's page): the window's web area
        // holds it. Not when a native text view has focus: its own selection is the answer
        // (TextEdit, Xcode, Notes), and the walk would only cost time.
        guard !Self.nativeTextRoles.contains(role ?? ""), let window = AX.element(app, kAXFocusedWindowAttribute),
              let (web, text) = Self.webSelection(in: window)
        else { return nil }
        let frame = AX.frame(web)
        let bounds = AX.boundsForSelectedTextMarker(web).flatMap {
            BoundsCheck.rejectionReason($0, elementFrame: frame) == nil ? ContextPacket.Rect($0) : nil
        }
        return ContextPacket.Selection(text: text, bounds: bounds, boundsSource: bounds == nil ? nil : .axTextMarker)
    }

    static let nativeTextRoles: Set<String> = [kAXTextAreaRole]
    static let listRoles: Set<String> = [kAXTableRole, kAXOutlineRole, kAXListRole, kAXBrowserRole, "AXCollection"]

    /// The first web area under `window` with a non-empty selection that isn't in a password
    /// field. Bounded by nodes, depth and wall clock, so a huge or hung app can't hold the packet.
    static func webSelection(in window: AXUIElement) -> (AXUIElement, String)? {
        firstSelection(
            from: window, role: { AX.string($0, kAXRoleAttribute) }, children: { AX.value($0, kAXChildrenAttribute) as? [AXUIElement] },
            selection: { web in
                if let focused = AX.element(web, kAXFocusedUIElementAttribute), AX.isSecure(focused) { return nil }
                return AX.selectedTextViaMarker(web)
            })
    }

    /// Breadth-first. List and table subtrees are skipped: a message or note list can hold hundreds
    /// of rows ahead of the viewer, and web content never sits inside one. Areas whose selection is
    /// empty (a collapsed caret) are passed over, so a later one with the real selection is found.
    static func firstSelection<Node>(
        from root: Node, role: (Node) -> String?, children: (Node) -> [Node]?, selection: (Node) -> String?,
        maxNodes: Int = 300, maxDepth: Int = 10, budget: Duration = .milliseconds(60),
        clock: () -> ContinuousClock.Instant = { .now }
    ) -> (Node, String)? {
        let start = clock()
        var queue: [(Node, Int)] = [(root, 0)]
        var head = 0
        while head < queue.count, head < maxNodes, clock() - start < budget {
            let (node, depth) = queue[head]
            head += 1
            let r = role(node) ?? ""
            if r == "AXWebArea", let text = selection(node), !text.isEmpty { return (node, text) }
            guard depth < maxDepth, !listRoles.contains(r), let kids = children(node) else { continue }
            queue.append(contentsOf: kids.map { ($0, depth + 1) })
        }
        return nil
    }

    /// Range bounds first, then the text-marker path. A rect that fails `BoundsCheck` is dropped.
    static func bounds(of el: AXUIElement) -> (ContextPacket.Rect?, ContextPacket.Selection.BoundsSource?) {
        let frame = AX.frame(el)
        if let range = AX.range(el, kAXSelectedTextRangeAttribute), range.length > 0,
           let r = AX.boundsForRange(el, range), BoundsCheck.rejectionReason(r, elementFrame: frame) == nil {
            return (ContextPacket.Rect(r), .axRange)
        }
        if let r = AX.boundsForSelectedTextMarker(el), BoundsCheck.rejectionReason(r, elementFrame: frame) == nil {
            return (ContextPacket.Rect(r), .axTextMarker)
        }
        return (nil, nil)
    }
}

/// Settable flags only: whether the focused element takes text and whether the selection is in
/// it. A selection in static page text (the web-area fallback) is never editable.
public struct AXEditableSensor: EditableSensor {
    public init() {}

    public func editable(pid: Int32) -> ContextPacket.Editable? {
        let app = AXUIElementCreateApplication(pid)
        guard let el = AX.element(app, kAXFocusedUIElementAttribute) else { return nil }
        let role = AX.string(el, kAXRoleAttribute)
        let subrole = AX.string(el, kAXSubroleAttribute)
        // Secure first: nothing else is read from a password field.
        guard !AX.isSecure(el, role: role) else { return nil }
        return Self.decide(
            role: role, subrole: subrole,
            selectedTextSettable: Self.settable(el, kAXSelectedTextAttribute),
            valueSettable: Self.settable(el, kAXValueAttribute),
            range: AX.range(el, kAXSelectedTextRangeAttribute))
    }

    static let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]

    /// Pure, so the rules are unit-tested. Settable selected text means a text control (sliders
    /// have none); a settable value counts only for a text role or with a text range, so sliders
    /// and steppers stay out while contenteditable composers count. A page itself never does.
    static func decide(
        role: String?, subrole: String?, selectedTextSettable: Bool, valueSettable: Bool, range: CFRange?
    ) -> ContextPacket.Editable? {
        if role == "AXSecureTextField" || subrole == kAXSecureTextFieldSubrole { return nil }
        if role == "AXWebArea" { return nil }
        let textual = textRoles.contains(role ?? "") || subrole == kAXSearchFieldSubrole || range != nil
        guard selectedTextSettable || (valueSettable && textual) else { return nil }
        return ContextPacket.Editable(field: true, selection: (range?.length ?? 0) > 0)
    }

    static func settable(_ el: AXUIElement, _ attr: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(el, attr as CFString, &settable) == .success && settable.boolValue
    }
}

public struct AXCursorSensor: CursorSensor {
    public init() {}

    public func cursor(skip: @Sendable (Int32) -> Bool) -> ContextPacket.Cursor? {
        // CGEvent locations are global points with a top-left origin, like AX.
        guard let p = CGEvent(source: nil)?.location else { return nil }
        var cursor = ContextPacket.Cursor(x: Double(p.x), y: Double(p.y))
        var hit: AXUIElement?
        if AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &hit) == .success,
           let el = hit, let pid = AX.pid(el), !skip(pid), !AX.isSecure(el),
           let role = AX.string(el, kAXRoleAttribute) {
            // Labels only; never the element's value, which can be what the user typed.
            let label = AX.string(el, kAXTitleAttribute) ?? AX.string(el, kAXDescriptionAttribute)
            cursor.element = ContextPacket.Element(role: role, label: label.map { String($0.prefix(200)) })
        }
        return cursor
    }
}

extension ContextPacket.Rect {
    init(_ r: CGRect) {
        self.init(x: Double(r.origin.x), y: Double(r.origin.y), width: Double(r.width), height: Double(r.height))
    }
}
