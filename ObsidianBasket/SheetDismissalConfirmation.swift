#if os(iOS)
    import SwiftUI
    import UIKit

    // In iOS 27 testing, sheet swipes bypassed SwiftUI's dismissal confirmation.
    // Check unsaved changes through the presentation delegate before allowing dismissal.
    struct SheetDismissalConfirmation: UIViewControllerRepresentable {
        let hasChanges: Bool
        let onDismissAttempt: () -> Void

        func makeUIViewController(context: Context) -> Controller {
            Controller()
        }

        func updateUIViewController(_ controller: Controller, context: Context) {
            controller.hasChanges = hasChanges
            controller.onDismissAttempt = onDismissAttempt
            DispatchQueue.main.async { [weak controller] in
                controller?.installDelegate()
            }
        }

        static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
            controller.restoreDelegate()
        }

        final class Controller: UIViewController, UIAdaptivePresentationControllerDelegate {
            var hasChanges = false
            var onDismissAttempt: (() -> Void)?
            private weak var observedPresentationController: UIPresentationController?
            private weak var previousDelegate: (any UIAdaptivePresentationControllerDelegate)?

            override func viewDidAppear(_ animated: Bool) {
                super.viewDidAppear(animated)
                installDelegate()
            }

            func installDelegate() {
                // The representable is a child of SwiftUI's sheet host. UIKit sends
                // dismissal callbacks to the host's presentation controller.
                var host: UIViewController = self
                while let parent = host.parent {
                    host = parent
                }
                guard host.presentingViewController != nil,
                    let presentationController = host.presentationController,
                    presentationController.delegate !== self
                else { return }

                restoreDelegate()
                observedPresentationController = presentationController
                previousDelegate = presentationController.delegate
                presentationController.delegate = self
            }

            func restoreDelegate() {
                if observedPresentationController?.delegate === self {
                    observedPresentationController?.delegate = previousDelegate
                }
                observedPresentationController = nil
                previousDelegate = nil
            }

            func presentationControllerShouldDismiss(_ presentationController: UIPresentationController)
                -> Bool
            {
                !hasChanges
                    && (previousDelegate?.presentationControllerShouldDismiss?(presentationController) ?? true)
            }

            func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController)
            {
                if hasChanges {
                    onDismissAttempt?()
                } else {
                    previousDelegate?.presentationControllerDidAttemptToDismiss?(presentationController)
                }
            }

            func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
                previousDelegate?.presentationControllerWillDismiss?(presentationController)
            }

            func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
                previousDelegate?.presentationControllerDidDismiss?(presentationController)
            }
        }
    }
#endif
