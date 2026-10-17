#if os(iOS)
    import SwiftUI
    import UIKit

    struct DisableSpellChecking: UIViewRepresentable {
        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        func makeUIView(context: Context) -> UIView {
            let view = UIView()
            context.coordinator.view = view
            return view
        }

        func updateUIView(_ view: UIView, context: Context) {}

        @MainActor final class Coordinator {
            weak var view: UIView?
            private var observation: NotificationCenter.ObservationToken?

            init() {
                observation = NotificationCenter.default.addObserver(
                    of: UITextField.self, for: .textDidBeginEditing
                ) { [weak self] message in
                    guard let window = self?.view?.window,
                        message.textField.window === window
                    else { return }

                    // SwiftUI's autocorrection setting leaves spelling replacements enabled.
                    message.textField.spellCheckingType = .no
                }
            }

            deinit {
                if let observation {
                    NotificationCenter.default.removeObserver(observation)
                }
            }
        }
    }
#endif
