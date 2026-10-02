import SwiftUI
import UIKit

/// Tap anywhere outside a text input to dismiss the keyboard, app-wide.
/// Doesn't cancel the tap, so buttons/toggles still work; taps on another field still move focus.
final class KeyboardDismissTap: NSObject, UIGestureRecognizerDelegate {
    static let shared = KeyboardDismissTap()

    func install() {
        let windows = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first,
              !(window.gestureRecognizers ?? []).contains(where: { $0.delegate === self }) else { return }
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismiss(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        window.addGestureRecognizer(tap)
    }

    @objc private func dismiss(_ tap: UITapGestureRecognizer) {
        tap.view?.endEditing(true)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let v = view {
            if v is UITextField || v is UITextView { return false }
            view = v.superview
        }
        return true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
