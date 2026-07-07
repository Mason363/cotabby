import ApplicationServices
import Foundation
import Logging

/// File overview:
/// Renders the focused AX element plus its ancestors and children to plain text and overwrites
/// `~/Desktop/cotabby-ax-dump.txt`, and — the point of this file — a **ground-truth probe** of the
/// focused element: the exact parameterized attributes it advertises and the live results of every
/// exact-geometry/font API Cotabby relies on (`AXBoundsForRange`, `AXBoundsForTextMarkerRange`,
/// `AXAttributedStringForRange`). This is how we tell, per app, whether an exact caret/font path is
/// available and merely being skipped versus genuinely unavailable — so resolution is fixed by fact,
/// not guesswork. Kept out of `FocusSnapshotResolver` so that hot path stays focused on snapshot
/// assembly rather than diagnostic disk I/O.
///
/// The dump only runs on debug builds (`-cotabby-debug`) and is debounced to one write per
/// focused-element identity change so rapid focus/value notifications inside one field don't
/// overwrite the file mid-inspection. It runs for whatever app is focused (not one hard-coded
/// bundle), so focusing a field in any app — Antinote, Obsidian, Notes — captures that app's
/// ground truth at the stable path. Writes are best-effort.
@MainActor
enum AXTreeDumpWriter {
    /// Last focused-element identifier we wrote to disk. The dump only runs when this changes, so
    /// rapid focus events inside the same field don't repeatedly overwrite the file mid-inspection.
    private static var lastDumpedElementID: String?
    private static let dumpTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Writes the AX tree dump + focused-element probe for `focusedElement`, but only on debug builds
    /// and only when the focused element changed since the last dump (debounced by element identity).
    /// A no-op otherwise. Runs for any app so focusing a field captures that app's ground truth.
    static func dumpIfEnabled(
        focusedElement: AXUIElement,
        applicationName: String,
        bundleIdentifier: String,
        focusedElementIdentifier: String
    ) {
        guard CotabbyDebugOptions.isEnabled,
              lastDumpedElementID != focusedElementIdentifier else {
            return
        }
        lastDumpedElementID = focusedElementIdentifier
        writeAXTreeDumpToDesktop(
            focusedElement: focusedElement,
            app: applicationName,
            bundle: bundleIdentifier
        )
    }

    /// Renders the focused element plus its ancestors and children to plain text and overwrites
    /// `~/Desktop/cotabby-ax-dump.txt`. The file is overwritten so the user (or an AI debugger)
    /// always inspects the latest snapshot at a stable path.
    ///
    /// Writes are best-effort: a failed disk write is logged through `CotabbyLogger.focus` and
    /// does not propagate, since AX dumping is purely diagnostic.
    private static func writeAXTreeDumpToDesktop(focusedElement: AXUIElement, app: String, bundle: String) {
        let timestamp = Self.dumpTimestampFormatter.string(from: Date())
        var out = "========== AX TREE DUMP ==========\n"
        out += "Timestamp: \(timestamp)\n"
        out += "App: \(app) (\(bundle))\n\n"

        out += "-- Focused + ancestors --\n"
        var ancestors: [AXUIElement] = [focusedElement]
        var currentElement = focusedElement
        for _ in 0..<3 {
            guard let parent = AXHelper.parentElement(of: currentElement) else { break }
            ancestors.append(parent)
            currentElement = parent
        }
        for (offset, element) in ancestors.enumerated().reversed() {
            let indent = String(repeating: "  ", count: ancestors.count - 1 - offset)
            out += describeNode(element, indent: indent)
        }

        out += "\n-- Children (depth 6) --\n"
        dumpChildrenRecursive(of: focusedElement, into: &out, indent: "", depth: 0)

        out += "\n-- Focused element probe (exact-data ground truth) --\n"
        out += focusedElementProbe(focusedElement)

        out += "========== END DUMP ==========\n"

        guard let desktopURL = FileManager.default
            .urls(for: .desktopDirectory, in: .userDomainMask).first else {
            CotabbyLogger.focus.error("AX dump skipped: no Desktop directory available")
            return
        }
        let targetURL = desktopURL.appendingPathComponent("cotabby-ax-dump.txt", isDirectory: false)
        do {
            try out.write(to: targetURL, atomically: true, encoding: .utf8)
            CotabbyLogger.focus.debug(
                "Wrote AX dump",
                metadata: [
                    "path": .string(targetURL.path),
                    "bundle": .string(bundle)
                ]
            )
        } catch {
            CotabbyLogger.focus.error(
                "Failed to write AX dump: \(error.localizedDescription)",
                metadata: ["path": .string(targetURL.path)]
            )
        }
    }

    private static func dumpChildrenRecursive(
        of element: AXUIElement,
        into out: inout String,
        indent: String,
        depth: Int
    ) {
        guard depth < 6 else { return }
        let children = AXHelper.childElements(of: element)
        for (offset, child) in children.prefix(20).enumerated() {
            out += describeNode(child, indent: "\(indent)[\(offset)] ")
            dumpChildrenRecursive(of: child, into: &out, indent: indent + "  ", depth: depth + 1)
        }
        if children.count > 20 {
            out += "\(indent)  ...+\(children.count - 20) more\n"
        }
    }

    private static func describeNode(_ element: AXUIElement, indent: String) -> String {
        let role = AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: element) ?? "?"
        let subrole = AXHelper.stringValue(for: kAXSubroleAttribute as CFString, on: element)
        let attributes = Set(AXHelper.attributeNames(on: element))
        let parameterizedAttributes = Set(AXHelper.parameterizedAttributeNames(on: element))

        var summary = "\(indent)\(role)"
        if let subrole { summary += " (\(subrole))" }
        summary += "\n"

        if let frame = AXHelper.rectValue(for: "AXFrame" as CFString, on: element) {
            let cocoa = AXHelper.cocoaRect(fromAccessibilityRect: frame)
            summary += "\(indent)  frame(AX): \(fmt(frame))  frame(cocoa): \(fmt(cocoa))\n"
        }

        if attributes.contains(kAXValueAttribute as String),
            let text = AXHelper.stringValue(for: kAXValueAttribute as CFString, on: element) {
            let previewText = text.count > 80 ? String(text.prefix(80)) + "…" : text
            summary += "\(indent)  value: " +
                "\"\(previewText.replacingOccurrences(of: "\n", with: "\\n"))\" " +
                "(len=\(text.count))\n"
        }

        if let range = AXHelper.rangeValue(for: kAXSelectedTextRangeAttribute as CFString, on: element) {
            summary += "\(indent)  selection: loc=\(range.location) len=\(range.length)\n"

            if parameterizedAttributes.contains(kAXBoundsForRangeParameterizedAttribute as String) {
                let boundsRect = AXHelper.parameterizedRectValue(
                    for: kAXBoundsForRangeParameterizedAttribute as CFString,
                    range: NSRange(location: range.location, length: 0),
                    on: element
                )
                if let boundsRect, !boundsRect.isEmpty {
                    summary += "\(indent)  BoundsForRange(loc,0): \(fmt(boundsRect))\n"
                } else {
                    summary += "\(indent)  BoundsForRange(loc,0): FAILED\n"
                }
            }
        }

        if let markerRect = AXHelper.textMarkerCaretRect(on: element), !markerRect.isEmpty {
            summary += "\(indent)  TextMarkerCaret: \(fmt(markerRect))\n"
        }

        if let isEditable = AXHelper.boolValue(for: "AXEditable" as CFString, on: element) {
            summary += "\(indent)  editable: \(isEditable)\n"
        }

        let childCount = AXHelper.childElements(of: element).count
        if childCount > 0 { summary += "\(indent)  children: \(childCount)\n" }

        return summary
    }

    /// Deep, exact-data probe of the focused element itself: the parameterized attributes it
    /// advertises and the live results of every exact-geometry/font API the resolver relies on. This
    /// is the ground truth that distinguishes "an exact path is available and being skipped" from
    /// "the datum is genuinely absent", so caret/font resolution is fixed per app by fact, not guess.
    private static func focusedElementProbe(_ element: AXUIElement) -> String {
        var out = ""
        let attrs = AXHelper.attributeNames(on: element).sorted()
        let paramAttrs = Set(AXHelper.parameterizedAttributeNames(on: element))
        out += "attributes: \(attrs.joined(separator: ", "))\n"
        out += "parameterized: \(paramAttrs.sorted().joined(separator: ", "))\n"

        let axFrame = AXHelper.rectValue(for: "AXFrame" as CFString, on: element)
        let anchor = axFrame.map(AXHelper.cocoaRect(fromAccessibilityRect:))
        if let axFrame, let anchor {
            out += "AXFrame: \(fmt(axFrame))  cocoa: \(fmt(anchor))\n"
        }

        let value = AXHelper.stringValue(for: kAXValueAttribute as CFString, on: element)
        let valueLength = (value as NSString?)?.length ?? 0
        out += "value length: \(valueLength)\n"

        // Selection: native NSRange (document offset) vs the marker-synthesized (window-relative) one.
        let nativeSelection = AXHelper.rangeValue(for: kAXSelectedTextRangeAttribute as CFString, on: element)
        let markerSelection = AXHelper.synthesizeMarkerSelection(on: element, parameterizedAttributes: paramAttrs)
        if let nativeSelection {
            out += "native selection: loc=\(nativeSelection.location) len=\(nativeSelection.length)\n"
        } else {
            out += "native selection: none\n"
        }
        if let markerSelection {
            let windowLen = (markerSelection.text as NSString).length
            out += "marker selection: caretOffset=\(markerSelection.selection.location) windowLen=\(windowLen)\n"
        } else {
            out += "marker selection: none\n"
        }

        // Exact caret geometry candidates. NSRange BoundsForRange only makes sense at a real document
        // offset, so it is tried only when a native selection exists.
        if let caretLocation = nativeSelection?.location {
            probeBoundsForRange(
                element, label: "BoundsForRange(caret,0)",
                range: NSRange(location: caretLocation, length: 0), anchor: anchor, into: &out)
            if caretLocation > 0 {
                probeBoundsForRange(
                    element, label: "BoundsForRange(caret-1,1)",
                    range: NSRange(location: caretLocation - 1, length: 1), anchor: anchor, into: &out)
            }
        } else {
            out += "BoundsForRange: skipped (no native selection; an NSRange offset would be window-relative)\n"
        }

        if let markerRect = AXHelper.textMarkerCaretRect(on: element) {
            let cocoa = AXHelper.validatedCocoaTextRect(fromAccessibilityRect: markerRect, anchorFrame: anchor)
            out += "textMarkerCaret: raw \(fmt(markerRect))  cocoa \(fmt(cocoa))  empty=\(markerRect.isEmpty)\n"
        } else {
            out += "textMarkerCaret: nil\n"
        }

        // Exact font/color via AXAttributedStringForRange.
        let fontCaret = nativeSelection?.location ?? markerSelection?.selection.location ?? 0
        let textLength = max(valueLength, (markerSelection?.text as NSString?)?.length ?? 0)
        if let style = AXHelper.resolveFieldStyle(for: element, caretLocation: fontCaret, textLength: textLength) {
            let size = style.fontPointSize.map { String(format: "%.1f", $0) } ?? "nil"
            out += "fieldStyle: font=\(style.fontName ?? "nil") size=\(size) color=\(style.colorHex ?? "nil")\n"
        } else {
            out += "fieldStyle: nil (no AXAttributedStringForRange font exposed)\n"
        }
        // Marker-based font fallback ground truth (Obsidian-class hosts fail the NSRange read above
        // but expose the style through their marker API).
        out += AXHelper.markerFieldStyleProbeDescription(on: element) + "\n"
        return out
    }

    /// Reports one `AXBoundsForRange` probe: raw rect, its Cocoa conversion, and whether that Cocoa
    /// rect passes the same 80pt anchor halo the resolver uses to accept/reject a bounds result.
    private static func probeBoundsForRange(
        _ element: AXUIElement,
        label: String,
        range: NSRange,
        anchor: CGRect?,
        into out: inout String
    ) {
        guard let raw = AXHelper.parameterizedRectValue(
            for: kAXBoundsForRangeParameterizedAttribute as CFString, range: range, on: element
        ) else {
            out += "\(label): FAILED\n"
            return
        }
        let cocoa = AXHelper.validatedCocoaTextRect(fromAccessibilityRect: raw, anchorFrame: anchor)
        let nearAnchor: String
        if let anchor, !anchor.isEmpty {
            let expanded = anchor.insetBy(dx: -80, dy: -80)
            nearAnchor = expanded.contains(CGPoint(x: cocoa.midX, y: cocoa.midY)) ? "nearAnchor=YES" : "nearAnchor=NO"
        } else {
            nearAnchor = "nearAnchor=?"
        }
        out += "\(label): raw \(fmt(raw))  cocoa \(fmt(cocoa))  \(nearAnchor)\n"
    }

    private static func fmt(_ rect: CGRect) -> String {
        String(format: "(%.0f, %.0f, %.0f×%.0f)", rect.origin.x, rect.origin.y, rect.width, rect.height)
    }
}
