#if os(iOS)
    import SwiftUI
    import UIKit

    // On iOS, native undo gestures need an active responder even when no text field is focused.
    struct UndoResponder: UIViewControllerRepresentable {
        let undoManager: UndoManager
        let focusRequest: UUID
        let isActive: Bool

        func makeUIViewController(context: Context) -> Controller {
            Controller()
        }

        func updateUIViewController(_ controller: Controller, context: Context) {
            let needsFocus = controller.focusRequest != focusRequest || controller.isActive != isActive
            controller.listUndoManager = undoManager
            controller.focusRequest = focusRequest
            controller.isActive = isActive
            if needsFocus {
                // Restore focus after the SwiftUI update so responder changes don't happen mid-update.
                DispatchQueue.main.async { [weak controller] in
                    controller?.restoreFocus()
                }
            }
        }

        final class Controller: UIViewController {
            var listUndoManager: UndoManager?
            var focusRequest: UUID?
            var isActive = false

            override var canBecomeFirstResponder: Bool { isActive }
            override var undoManager: UndoManager? { isActive ? listUndoManager : nil }
            override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .default }

            override func viewDidAppear(_ animated: Bool) {
                super.viewDidAppear(animated)
                restoreFocus()
            }

            func restoreFocus() {
                if isActive {
                    guard view.window != nil else { return }
                    becomeFirstResponder()
                } else if isFirstResponder {
                    resignFirstResponder()
                }
            }
        }
    }
#endif
