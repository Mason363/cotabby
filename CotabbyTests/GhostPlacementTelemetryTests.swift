import Logging
import XCTest

@testable import Cotabby

/// Pins the placement-telemetry record shape: field names, rounding, optional-group omission, and
/// the text hash. Downstream `jq` recipes (the teleport detector, the rendered-pixel probe) key on
/// these exact names and formats, so a rename here is a breaking change to the measurement tooling.
final class GhostPlacementTelemetryTests: XCTestCase {
    private func geometry(
        caretRect: CGRect = CGRect(x: 100.123, y: 200.456, width: 2, height: 18.5),
        inputFrameRect: CGRect? = nil
    ) -> SuggestionOverlayGeometry {
        SuggestionOverlayGeometry(
            caretRect: caretRect,
            inputFrameRect: inputFrameRect,
            caretQuality: .derived,
            observedCharWidth: nil,
            isRightToLeft: false,
            focusChangeSequence: 7,
            focusedInputIdentityKey: 9
        )
    }

    func test_metadata_coreFieldsAlwaysPresent() {
        let metadata = GhostPlacementTelemetry.metadata(
            event: .inlineShow,
            presentation: nil,
            geometry: geometry(),
            text: "hello",
            renderMode: nil,
            policyReason: nil,
            hysteresis: nil,
            fontPath: nil,
            fontName: nil,
            fontSize: nil,
            glyphBoxHeight: nil,
            lineHeight: nil,
            panelFrame: nil,
            contentHeight: nil,
            lineCount: nil,
            advanceShift: nil,
            hideReason: nil
        )

        XCTAssertEqual(metadata["stage"], .string("overlay-present"))
        XCTAssertEqual(metadata["event"], .string("inline_show"))
        XCTAssertEqual(metadata["caret_quality"], .string("derived"))
        XCTAssertEqual(metadata["text_len"], .stringConvertible(5))
        XCTAssertEqual(metadata["text_hash"], .string(GhostPlacementTelemetry.textHash("hello")))
        XCTAssertNotNil(metadata["caret_x"])
        XCTAssertNotNil(metadata["caret_min_y"])
        XCTAssertNotNil(metadata["caret_h"])
        XCTAssertNotNil(metadata["focus_change_sequence"])
        XCTAssertNotNil(metadata["input_identity_key"])
    }

    func test_metadata_optionalGroupsOmittedWhenNil() {
        let metadata = GhostPlacementTelemetry.metadata(
            event: .hide,
            presentation: nil,
            geometry: geometry(),
            text: "x",
            renderMode: nil,
            policyReason: nil,
            hysteresis: nil,
            fontPath: nil,
            fontName: nil,
            fontSize: nil,
            glyphBoxHeight: nil,
            lineHeight: nil,
            panelFrame: nil,
            contentHeight: nil,
            lineCount: nil,
            advanceShift: nil,
            hideReason: nil
        )

        for absent in [
            "request_id", "work_id", "host_bundle_id", "caret_source", "render_mode",
            "policy_reason", "hysteresis", "font_path", "font_name", "font_size",
            "glyph_box_h", "line_height", "panel_x", "panel_y", "panel_w", "panel_h",
            "content_h", "line_count", "advance_shift", "hide_reason",
            "input_frame_x", "input_frame_y", "input_frame_w", "input_frame_h"
        ] {
            XCTAssertNil(metadata[absent], "expected \(absent) to be omitted")
        }
    }

    func test_metadata_carriesInputFrameWhenKnown() {
        let metadata = GhostPlacementTelemetry.metadata(
            event: .inlineShow,
            presentation: nil,
            geometry: geometry(inputFrameRect: CGRect(x: 50, y: 60.126, width: 800, height: 120)),
            text: "t",
            renderMode: nil,
            policyReason: nil,
            hysteresis: nil,
            fontPath: nil,
            fontName: nil,
            fontSize: nil,
            glyphBoxHeight: nil,
            lineHeight: nil,
            panelFrame: nil,
            contentHeight: nil,
            lineCount: nil,
            advanceShift: nil,
            hideReason: nil
        )

        XCTAssertEqual(metadata["input_frame_x"], .stringConvertible(50.0))
        XCTAssertEqual(metadata["input_frame_y"], .stringConvertible(60.13))
        XCTAssertEqual(metadata["input_frame_w"], .stringConvertible(800.0))
        XCTAssertEqual(metadata["input_frame_h"], .stringConvertible(120.0))
    }

    func test_metadata_fullRecordCarriesEveryGroup() {
        let presentation = OverlayPresentationContext(
            requestID: "req_test1",
            workID: 42,
            hostBundleID: "md.obsidian",
            caretSource: "derived primary"
        )
        let metadata = GhostPlacementTelemetry.metadata(
            event: .inlineShow,
            presentation: presentation,
            geometry: geometry(),
            text: " world",
            renderMode: "inline",
            policyReason: nil,
            hysteresis: .rerenderedInline,
            fontPath: .trustedReported,
            fontName: "Menlo-Regular",
            fontSize: 14,
            glyphBoxHeight: 16.404296875,
            lineHeight: 18,
            panelFrame: CGRect(x: 10, y: 20.567, width: 120, height: 22),
            contentHeight: 21.5,
            lineCount: 1,
            advanceShift: nil,
            hideReason: nil
        )

        XCTAssertEqual(metadata["request_id"], .string("req_test1"))
        XCTAssertEqual(metadata["work_id"], .stringConvertible(UInt64(42)))
        XCTAssertEqual(metadata["host_bundle_id"], .string("md.obsidian"))
        XCTAssertEqual(metadata["caret_source"], .string("derived primary"))
        XCTAssertEqual(metadata["render_mode"], .string("inline"))
        XCTAssertEqual(metadata["hysteresis"], .string("rerendered_inline"))
        XCTAssertEqual(metadata["font_path"], .string("trusted_reported"))
        XCTAssertEqual(metadata["font_name"], .string("Menlo-Regular"))
        XCTAssertEqual(metadata["panel_y"], .stringConvertible(20.57))
        XCTAssertEqual(metadata["glyph_box_h"], .stringConvertible(16.4))
        XCTAssertEqual(metadata["line_count"], .stringConvertible(1))
    }

    func test_metadata_missingRequestIDBecomesSentinel() {
        let presentation = OverlayPresentationContext(
            requestID: nil,
            workID: 1,
            hostBundleID: nil,
            caretSource: "exact primary"
        )
        let metadata = GhostPlacementTelemetry.metadata(
            event: .holdInline,
            presentation: presentation,
            geometry: geometry(),
            text: "t",
            renderMode: "inline",
            policyReason: nil,
            hysteresis: .held,
            fontPath: nil,
            fontName: nil,
            fontSize: nil,
            glyphBoxHeight: nil,
            lineHeight: nil,
            panelFrame: nil,
            contentHeight: nil,
            lineCount: nil,
            advanceShift: nil,
            hideReason: nil
        )

        XCTAssertEqual(metadata["request_id"], .string("req_none"))
        XCTAssertNil(metadata["host_bundle_id"])
    }

    func test_metadata_roundsCoordinatesToTwoDecimals() {
        let metadata = GhostPlacementTelemetry.metadata(
            event: .inlineShow,
            presentation: nil,
            geometry: geometry(caretRect: CGRect(x: 1.005, y: 2.999, width: 2, height: 18.123456)),
            text: "a",
            renderMode: nil,
            policyReason: nil,
            hysteresis: nil,
            fontPath: nil,
            fontName: nil,
            fontSize: nil,
            glyphBoxHeight: nil,
            lineHeight: nil,
            panelFrame: nil,
            contentHeight: nil,
            lineCount: nil,
            advanceShift: nil,
            hideReason: nil
        )

        XCTAssertEqual(metadata["caret_min_y"], .stringConvertible(3.0))
        XCTAssertEqual(metadata["caret_h"], .stringConvertible(18.12))
    }

    func test_textHash_isStableAcrossCallsAndDiffersByContent() {
        // FNV-1a 64 published vectors: offset basis for "", 0xaf63dc4c8601ec8c for "a".
        XCTAssertEqual(GhostPlacementTelemetry.textHash(""), "cbf29ce484222325")
        XCTAssertEqual(GhostPlacementTelemetry.textHash("a"), "af63dc4c8601ec8c")
        XCTAssertEqual(
            GhostPlacementTelemetry.textHash("same tail"),
            GhostPlacementTelemetry.textHash("same tail")
        )
        XCTAssertNotEqual(
            GhostPlacementTelemetry.textHash("same tail"),
            GhostPlacementTelemetry.textHash("same tail ")
        )
    }
}
