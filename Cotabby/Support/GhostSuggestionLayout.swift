import AppKit
import CoreGraphics
import Foundation

/// Computes the visual line layout for ghost text before `OverlayController` renders it.
///
/// Keeping this as a pure value helper gives us a clear boundary: the helper answers "where should
/// the text lines go?", while `OverlayController` answers "how do we place the non-activating
/// AppKit panel?". That split matters because wrapping bugs are layout bugs, not window lifecycle
/// bugs.
struct GhostSuggestionLayout: Equatable {
    struct Line: Equatable, Identifiable {
        let index: Int
        let text: String
        let leadingIndent: CGFloat
        let showsKeycap: Bool

        var id: Int { index }
    }

    let lines: [Line]
    /// For LTR, the left edge of the panel. For RTL, the right-edge anchor — `panelFrame()`
    /// subtracts the content width to derive the actual AppKit origin.
    let panelOriginX: CGFloat
    let lineHeight: CGFloat
    /// Natural glyph-box height (ascender − descender) of the render font, `lineHeight` when the
    /// font is unknown. The row is taller than the glyph box (`lineHeightMultiplier` leading), and
    /// the row centers its glyphs, so the glyphs float `(lineHeight − glyphBoxHeight) / 2` above the
    /// row bottom; `panelFrame` subtracts exactly that so the glyphs — not the row box — land on the
    /// caret line.
    let glyphBoxHeight: CGFloat
    let topLineCenterOffsetFromCaret: CGFloat
    let isRightToLeft: Bool

    private enum Metrics {
        static let inputHorizontalPadding: CGFloat = 8
        static let fallbackScreenMargin: CGFloat = 16
        static let minimumLineWidth: CGFloat = 48
        static let estimatedKeycapAndSpacingWidth: CGFloat = 36
        static let lineHeightMultiplier: CGFloat = 1.25
    }

    /// Inputs for measuring rendered text width: the size, the AX-observed average char width when
    /// available, and the host field font used for the fallback measurement. Bundled so the wrapping
    /// helpers stay within a small parameter count and so width is measured with the rendered glyphs.
    private struct TextMeasure {
        let fontSize: CGFloat
        let observedCharWidth: CGFloat?
        let font: NSFont?
    }

    static func make(
        text: String,
        geometry: SuggestionOverlayGeometry,
        fontSize: CGFloat,
        visibleFrame: CGRect,
        showsAcceptanceHint: Bool = true,
        font: NSFont? = nil
    ) -> GhostSuggestionLayout {
        let normalizedText = normalizedDisplayText(text)
        let lineHeight = ceil(fontSize * Metrics.lineHeightMultiplier)
        // The render font's natural glyph-box height, for glyph-level (not box-level) vertical
        // anchoring in `panelFrame`. Falls back to the row height when no font is known, which
        // degrades to plain bottom-alignment there.
        let glyphBoxHeight = font.map { $0.ascender - $0.descender } ?? lineHeight
        let isRTL = geometry.isRightToLeft
        let measure = TextMeasure(
            fontSize: fontSize,
            observedCharWidth: geometry.observedCharWidth,
            font: font
        )
        // When the keycap is hidden the text can use the full width, so we stop reserving room for it.
        let keycapReservation = showsAcceptanceHint ? Metrics.estimatedKeycapAndSpacingWidth : 0
        let usableFrame = usableTextFrame(
            geometry: geometry,
            visibleFrame: visibleFrame
        )

        // Anchor the ghost's first glyph exactly at the caret's insertion point so the suggestion
        // occupies the pixels a typed glyph would — accepting or typing through it then produces no
        // horizontal shift. The resolver builds every caret rect with its origin (`minX`) at the
        // insertion point and a synthetic 2pt width extending rightward, so the insertion point is
        // `caretRect.minX` in both writing directions (not `maxX`, which would sit a caret-width to
        // the right). No gap is added: a gap is exactly the "slightly after the cursor" drift we want
        // gone; any real word separation is already baked into the suggestion text itself.
        // LTR: the anchor is the left edge; the budget extends rightward.
        // RTL: the anchor is the right edge (panelFrame subtracts content width); budget extends left.
        let caretInsertionX = geometry.caretRect.minX
        let firstLineAnchor = min(max(caretInsertionX, usableFrame.minX), usableFrame.maxX)
        let firstLineBudget: CGFloat
        if isRTL {
            firstLineBudget = max(
                0,
                firstLineAnchor - usableFrame.minX - keycapReservation
            )
        } else {
            firstLineBudget = max(
                0,
                usableFrame.maxX - firstLineAnchor - keycapReservation
            )
        }

        let overflowBudget = max(
            Metrics.minimumLineWidth,
            usableFrame.width - keycapReservation
        )

        let singleLineFits = !normalizedText.contains("\n")
            && measuredWidth(of: normalizedText, using: measure) <= firstLineBudget

        if singleLineFits {
            return GhostSuggestionLayout(
                lines: [
                    Line(index: 0, text: normalizedText, leadingIndent: 0, showsKeycap: showsAcceptanceHint)
                ],
                panelOriginX: firstLineAnchor,
                lineHeight: lineHeight,
                glyphBoxHeight: glyphBoxHeight,
                topLineCenterOffsetFromCaret: 0,
                isRightToLeft: isRTL
            )
        }

        // Multi-line wrapping. The panel spans the full usable width so overflow lines can
        // use the entire field. The first line is indented to stay aligned with the caret.
        let panelOriginX = isRTL ? usableFrame.maxX : usableFrame.minX
        var remainingText = normalizedText
        var rawLines: [(text: String, leadingIndent: CGFloat)] = []
        var startsBelowCaret = false

        if firstLineBudget >= Metrics.minimumLineWidth {
            let split = splitPrefix(
                from: remainingText,
                maxWidth: firstLineBudget,
                using: measure
            )
            if !split.line.isEmpty {
                let indent: CGFloat
                if isRTL {
                    indent = panelOriginX - firstLineAnchor
                } else {
                    indent = firstLineAnchor - panelOriginX
                }
                rawLines.append((split.line, indent))
                remainingText = split.remainder
            } else {
                startsBelowCaret = true
            }
        } else {
            startsBelowCaret = true
        }

        while !remainingText.isEmpty {
            let split = splitPrefix(
                from: remainingText,
                maxWidth: overflowBudget,
                using: measure
            )
            guard !split.line.isEmpty else {
                break
            }

            rawLines.append((split.line, 0))
            remainingText = split.remainder
        }

        if rawLines.isEmpty {
            rawLines.append((normalizedText, 0))
            startsBelowCaret = true
        }

        let finalLines = rawLines.enumerated().map { offset, rawLine in
            Line(
                index: offset,
                text: rawLine.text,
                leadingIndent: rawLine.leadingIndent,
                showsKeycap: showsAcceptanceHint && offset == rawLines.count - 1
            )
        }

        return GhostSuggestionLayout(
            lines: finalLines,
            panelOriginX: panelOriginX,
            lineHeight: lineHeight,
            glyphBoxHeight: glyphBoxHeight,
            topLineCenterOffsetFromCaret: startsBelowCaret ? -lineHeight : 0,
            isRightToLeft: isRTL
        )
    }

    func panelFrame(for contentSize: CGSize, caretRect: CGRect) -> CGRect {
        let originX = isRightToLeft ? panelOriginX - contentSize.width : panelOriginX

        let originY: CGFloat
        if lines.count == 1 {
            // Anchor the GLYPHS, not the panel box, to the caret line. Two upward biases made the
            // ghost sit "a little too high" everywhere (the recurring field report):
            //   • the old midpoint formula raised the panel by (caretHeight − contentHeight)/4
            //     whenever the host line box was taller than the ghost row — i.e. in every editor
            //     with generous line spacing;
            //   • the row itself centers its glyphs, so they float (lineHeight − glyphBoxHeight)/2
            //     above the row bottom.
            // Compensating both places the ghost's glyph-box bottom on the caret rect's bottom —
            // the line the host's own glyphs sit on.
            originY = caretRect.minY - max(0, (lineHeight - glyphBoxHeight) / 2)
        } else {
            // Multi-line stacks from the caret's line downward using the layout's line height; the
            // wrapped tail must keep flowing below, so the top-anchored math is retained here.
            let topLineCenterY = caretRect.midY + topLineCenterOffsetFromCaret
            originY = topLineCenterY - contentSize.height + (lineHeight / 2)
        }

        return CGRect(
            origin: CGPoint(x: originX, y: originY),
            size: contentSize
        )
    }

    private static func usableTextFrame(
        geometry: SuggestionOverlayGeometry,
        visibleFrame: CGRect
    ) -> CGRect {
        if let inputFrame = geometry.inputFrameRect?.standardized,
           inputFrame.width > Metrics.minimumLineWidth {
            let minX = max(
                inputFrame.minX + Metrics.inputHorizontalPadding,
                visibleFrame.minX + Metrics.fallbackScreenMargin
            )
            let maxX = min(
                inputFrame.maxX - Metrics.inputHorizontalPadding,
                visibleFrame.maxX - Metrics.fallbackScreenMargin
            )

            if maxX - minX > Metrics.minimumLineWidth {
                return CGRect(
                    x: minX,
                    y: inputFrame.minY,
                    width: maxX - minX,
                    height: inputFrame.height
                )
            }
        }

        // Fallback when no input frame is available. For LTR, use the area from the caret's insertion
        // point (its left edge) rightward; for RTL, from the left margin up to the insertion point.
        // Anchoring on `caretRect.minX` in both directions keeps the usable region flush with where a
        // typed glyph would land, matching the gap-free first-line anchor above.
        let fallbackMinX: CGFloat
        let fallbackMaxX: CGFloat
        if geometry.isRightToLeft {
            fallbackMinX = visibleFrame.minX + Metrics.fallbackScreenMargin
            fallbackMaxX = geometry.caretRect.minX
        } else {
            fallbackMinX = geometry.caretRect.minX
            fallbackMaxX = visibleFrame.maxX - Metrics.fallbackScreenMargin
        }

        return CGRect(
            x: fallbackMinX,
            y: geometry.caretRect.minY,
            width: max(Metrics.minimumLineWidth, fallbackMaxX - fallbackMinX),
            height: geometry.caretRect.height
        )
    }

    /// The width `text` actually occupies as a single rendered ghost line: the normalized display
    /// string measured with the real render `font` via Core Text glyph layout (not the average
    /// char-width budget `measuredWidth` uses for wrapping). Used to slide the overlay by the exact
    /// width of accepted text so the remaining tail stays on the same pixels. Measuring the string
    /// (not a character count) keeps graphemes, surrogate pairs, and whitespace normalization correct.
    ///
    /// Note: a `width(before) - width(after)` advance double-counts the kerning pair at the
    /// accepted/remaining seam by a sub-point amount for proportional fonts (each side is measured
    /// without the other's adjacent glyph). That residual is far inside the overlay's caret drift
    /// tolerance, and the stability gate's re-anchor caps any accumulation under rapid acceptance.
    static func renderedWidth(of text: String, font: NSFont) -> CGFloat {
        let display = normalizedDisplayText(text)
        guard !display.isEmpty else { return 0 }
        return (display as NSString).size(withAttributes: [.font: font]).width
    }

    private static func normalizedDisplayText(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let normalizedLines = lines.map { line -> String in
            let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !words.isEmpty else { return "" }
            let joined = words.joined(separator: " ")
            return line.first?.isWhitespace == true ? " \(joined)" : joined
        }
        return normalizedLines.joined(separator: "\n")
    }

    private static func splitPrefix(
        from text: String,
        maxWidth: CGFloat,
        using measure: TextMeasure
    ) -> (line: String, remainder: String) {
        let source = text.trimmingCharacters(in: .whitespaces)
        guard !source.isEmpty else {
            return ("", "")
        }

        let safeMaxWidth = max(maxWidth, Metrics.minimumLineWidth)

        // Explicit newline: force a line break at the first one.
        if let newlineIndex = source.firstIndex(of: "\n") {
            return splitAtNewline(
                source: source,
                newlineIndex: newlineIndex,
                maxWidth: maxWidth,
                using: measure
            )
        }

        if measuredWidth(of: source, using: measure) <= safeMaxWidth {
            return (source, "")
        }

        let characters = Array(source)
        var lastWhitespaceBreak: Int?

        for endIndex in characters.indices {
            let prefix = String(characters[...endIndex])
            if characters[endIndex].isWhitespace {
                lastWhitespaceBreak = endIndex + 1
            }

            if measuredWidth(of: prefix, using: measure) > safeMaxWidth {
                if let breakIndex = lastWhitespaceBreak, breakIndex > 0 {
                    let line = String(characters[..<breakIndex])
                        .trimmingCharacters(in: .whitespaces)
                    let remainder = String(characters[breakIndex...])
                        .trimmingCharacters(in: .whitespaces)
                    return (line, remainder)
                }

                let splitIndex = max(endIndex, 1)
                let line = String(characters[..<splitIndex])
                    .trimmingCharacters(in: .whitespaces)
                let remainder = String(characters[splitIndex...])
                    .trimmingCharacters(in: .whitespaces)
                return (line, remainder)
            }
        }

        return (text.trimmingCharacters(in: .whitespaces), "")
    }

    /// Splits `source` at its first explicit newline, width-wrapping the leading segment if it overflows.
    private static func splitAtNewline(
        source: String,
        newlineIndex: String.Index,
        maxWidth: CGFloat,
        using measure: TextMeasure
    ) -> (line: String, remainder: String) {
        let safeMaxWidth = max(maxWidth, Metrics.minimumLineWidth)
        let segment = String(source[..<newlineIndex]).trimmingCharacters(in: .whitespaces)
        let afterIndex = source.index(after: newlineIndex)
        let afterNewline = afterIndex < source.endIndex
            ? String(source[afterIndex...]).trimmingCharacters(in: .whitespaces)
            : ""

        guard !segment.isEmpty else {
            return splitPrefix(from: afterNewline, maxWidth: maxWidth, using: measure)
        }

        if measuredWidth(of: segment, using: measure) <= safeMaxWidth {
            return (segment, afterNewline)
        }

        // Segment before newline is too wide — width-wrap it, keep post-newline as remainder.
        let widthSplit = splitPrefix(from: segment, maxWidth: maxWidth, using: measure)
        let combined: String
        if widthSplit.remainder.isEmpty {
            combined = afterNewline
        } else if afterNewline.isEmpty {
            combined = widthSplit.remainder
        } else {
            combined = widthSplit.remainder + "\n" + afterNewline
        }
        return (widthSplit.line, combined)
    }

    private static func measuredWidth(of text: String, using measure: TextMeasure) -> CGFloat {
        if let observedCharWidth = measure.observedCharWidth, observedCharWidth > 0 {
            return CGFloat((text as NSString).length) * observedCharWidth
        }

        // Measure with the host field's font when known so wrapping matches the rendered glyphs;
        // this matters most in monospace editors where the system font's advances differ.
        return (text as NSString).size(withAttributes: [
            .font: measure.font ?? NSFont.systemFont(ofSize: measure.fontSize)
        ]).width
    }
}
