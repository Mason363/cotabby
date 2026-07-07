import CoreGraphics
import Foundation
import Logging

/// File overview:
/// Builds the flat `Logger.Metadata` for per-present ghost placement records (`stage:
/// "overlay-present"`). Every overlay show/hold/slide/hide emits one record carrying the caret
/// geometry, the render decision, the font-resolution path, and the panel frame actually applied,
/// so a misplaced ghost can be diagnosed numerically from the JSONL stream instead of eyeballed.
///
/// Kept as a pure value helper (no AppKit, no AX, no logger) so the field names and formatting are
/// unit-testable and stable — downstream `jq` recipes (e.g. the teleport detector) key on them.
nonisolated enum GhostPlacementTelemetry {
    /// Which overlay transition produced the record. Raw values are the JSONL `event` field.
    enum Event: String {
        /// Inline ghost rendered (fresh present or reposition) — carries the full placement record.
        case inlineShow = "inline_show"
        /// Mirror card rendered — placement anchors to the field rect, `policy_reason` says why.
        case mirrorShow = "mirror_show"
        /// A visible inline ghost slid right by `advance_shift` instead of re-anchoring to AX.
        case advanceInline = "advance_inline"
        /// Hysteresis left the visible inline panel untouched; the record carries the *rejected*
        /// incoming caret so hold decisions are countable against what they ignored.
        case holdInline = "hold_inline"
        /// The panel was ordered out; carries the hide reason and the last visible frame.
        case hide
    }

    /// Which path resolved the rendered font size — ground truth from the resolver, not re-inferred.
    enum FontPath: String {
        /// The host's own AX-reported point size was used directly.
        case trustedReported = "trusted_reported"
        /// The text-layout estimator's resolved size was used (`.layoutEstimated` caret).
        case trustedLayoutEstimated = "trusted_layout_estimated"
        /// Derived from caret height via the field font's glyph-box ratio.
        case caretDerived = "caret_derived"
        /// Derived from caret height via the fixed fallback ratio (no usable field metrics).
        case fallbackRatio = "fallback_ratio"
    }

    /// What the caret-quality hysteresis in `OverlayController.resolvePresentation` decided.
    enum Hysteresis: String {
        /// The policy mode was rendered as-is.
        case none
        /// The visible inline panel was held untouched through a transient quality dip.
        case held
        /// The policy asked for the card, but the hysteresis re-rendered inline at the fresh caret.
        case rerenderedInline = "rerendered_inline"
    }

    // swiftlint:disable cyclomatic_complexity function_body_length
    /// The one metadata builder for every event. Optional groups are simply absent from the record
    /// when nil, so each event only carries the fields it genuinely measured. All keys are flat —
    /// `FileLogHandler` emits metadata as top-level JSON fields, which keeps them `jq`-filterable.
    /// The branchiness is one `if let` per optional field — flat and mechanical by design.
    static func metadata(
        event: Event,
        presentation: OverlayPresentationContext?,
        geometry: SuggestionOverlayGeometry,
        text: String,
        renderMode: String? = nil,
        policyReason: String? = nil,
        hysteresis: Hysteresis? = nil,
        fontPath: FontPath? = nil,
        fontName: String? = nil,
        fontSize: CGFloat? = nil,
        glyphBoxHeight: CGFloat? = nil,
        lineHeight: CGFloat? = nil,
        panelFrame: CGRect? = nil,
        contentHeight: CGFloat? = nil,
        lineCount: Int? = nil,
        advanceShift: CGFloat? = nil,
        hideReason: String? = nil
    ) -> Logger.Metadata {
        var metadata: Logger.Metadata = [
            "stage": .string("overlay-present"),
            "event": .string(event.rawValue),
            "caret_x": .stringConvertible(rounded(geometry.caretRect.minX)),
            "caret_min_y": .stringConvertible(rounded(geometry.caretRect.minY)),
            "caret_h": .stringConvertible(rounded(geometry.caretRect.height)),
            "caret_quality": .string(String(describing: geometry.caretQuality)),
            "caret_at_eol": .stringConvertible(geometry.isCaretAtEndOfLine),
            "focus_change_sequence": .stringConvertible(geometry.focusChangeSequence),
            "input_identity_key": .stringConvertible(geometry.focusedInputIdentityKey),
            "is_rtl": .stringConvertible(geometry.isRightToLeft),
            "is_correction": .stringConvertible(geometry.isCorrection),
            "text_len": .stringConvertible(text.utf16.count),
            "text_hash": .string(textHash(text))
        ]
        // The host field's rectangle, when known. Paired with the panel frame this makes overflow
        // ("ghost text escaped the text box") a computable predicate on every record instead of a
        // visual anecdote: horizontal overflow is panel_x + panel_w > input_frame_x + input_frame_w.
        if let inputFrame = geometry.inputFrameRect {
            metadata["input_frame_x"] = .stringConvertible(rounded(inputFrame.minX))
            metadata["input_frame_y"] = .stringConvertible(rounded(inputFrame.minY))
            metadata["input_frame_w"] = .stringConvertible(rounded(inputFrame.width))
            metadata["input_frame_h"] = .stringConvertible(rounded(inputFrame.height))
        }
        if let presentation {
            metadata["request_id"] = .string(presentation.requestID ?? "req_none")
            metadata["work_id"] = .stringConvertible(presentation.workID)
            if let bundleID = presentation.hostBundleID {
                metadata["host_bundle_id"] = .string(bundleID)
            }
            metadata["caret_source"] = .string(presentation.caretSource)
        }
        if let renderMode { metadata["render_mode"] = .string(renderMode) }
        if let policyReason { metadata["policy_reason"] = .string(policyReason) }
        if let hysteresis { metadata["hysteresis"] = .string(hysteresis.rawValue) }
        if let fontPath { metadata["font_path"] = .string(fontPath.rawValue) }
        if let fontName { metadata["font_name"] = .string(fontName) }
        if let fontSize { metadata["font_size"] = .stringConvertible(rounded(fontSize)) }
        if let glyphBoxHeight { metadata["glyph_box_h"] = .stringConvertible(rounded(glyphBoxHeight)) }
        if let lineHeight { metadata["line_height"] = .stringConvertible(rounded(lineHeight)) }
        if let panelFrame {
            metadata["panel_x"] = .stringConvertible(rounded(panelFrame.minX))
            metadata["panel_y"] = .stringConvertible(rounded(panelFrame.minY))
            metadata["panel_w"] = .stringConvertible(rounded(panelFrame.width))
            metadata["panel_h"] = .stringConvertible(rounded(panelFrame.height))
        }
        if let contentHeight { metadata["content_h"] = .stringConvertible(rounded(contentHeight)) }
        if let lineCount { metadata["line_count"] = .stringConvertible(lineCount) }
        if let advanceShift { metadata["advance_shift"] = .stringConvertible(rounded(advanceShift)) }
        if let hideReason { metadata["hide_reason"] = .string(hideReason) }
        return metadata
    }
    // swiftlint:enable cyclomatic_complexity function_body_length

    /// Stable FNV-1a 64-bit hash of the suggestion text, hex-encoded. Lets records be correlated
    /// by "same suggestion tail" (the teleport detector's grouping key) without ever logging the
    /// user's text content.
    static func textHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000000100000001b3
        }
        return String(hash, radix: 16)
    }

    /// Two-decimal rounding: enough precision to see sub-point placement drift, stable enough that
    /// records diff cleanly.
    private static func rounded(_ value: CGFloat) -> Double {
        (Double(value) * 100).rounded() / 100
    }
}
