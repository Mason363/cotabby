import XCTest
@testable import Cotabby

/// Guards the delete-detection that drives backspace-burst overlay suppression.
final class CapturedInputEventTests: XCTestCase {
    private func event(kind: CapturedInputEvent.Kind, keyCode: CGKeyCode) -> CapturedInputEvent {
        CapturedInputEvent(kind: kind, keyCode: keyCode, characters: "", flags: [])
    }

    func test_backspaceIsDeletion() {
        XCTAssertTrue(event(kind: .textMutation, keyCode: 51).isDeletion)
    }

    func test_forwardDeleteIsDeletion() {
        XCTAssertTrue(event(kind: .textMutation, keyCode: 117).isDeletion)
    }

    func test_typedCharacterIsNotDeletion() {
        // A normal character mutation shares the .textMutation kind but is not a delete.
        XCTAssertFalse(event(kind: .textMutation, keyCode: 0).isDeletion)
    }

    func test_nonMutationKeysAreNotDeletion() {
        XCTAssertFalse(event(kind: .dismissal, keyCode: 51).isDeletion)
        XCTAssertFalse(event(kind: .navigation, keyCode: 117).isDeletion)
        XCTAssertFalse(event(kind: .acceptance, keyCode: 48).isDeletion)
    }
}
