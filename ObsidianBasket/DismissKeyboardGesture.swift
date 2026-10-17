#if os(iOS)
    import SwiftUI
    import UIKit

    struct DismissKeyboardGesture: UIGestureRecognizerRepresentable {
        func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
            Coordinator()
        }

        func makeUIGestureRecognizer(context: Context) -> UITapGestureRecognizer {
            let recognizer = UITapGestureRecognizer()
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = context.coordinator
            return recognizer
        }

        func handleUIGestureRecognizerAction(_ recognizer: UITapGestureRecognizer, context: Context) {
            if recognizer.state == .ended {
                recognizer.view?.window?.endEditing(true)
            }
        }

        final class Coordinator: NSObject, UIGestureRecognizerDelegate {
            func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch)
                -> Bool
            {
                var view = touch.view
                while let ancestor = view {
                    // Leave buttons and text editing alone so their taps don't dismiss the keyboard.
                    if ancestor is UIControl || ancestor is UITextView {
                        return false
                    }
                    view = ancestor.superview
                }
                return true
            }
        }
    }
#endif
