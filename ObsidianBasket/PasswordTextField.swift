#if os(iOS)
    import SwiftUI
    import UIKit

    // Keep one field on iOS so revealing a password doesn't change its size or restart the keyboard.
    struct PasswordTextField: UIViewRepresentable {
        @Binding var text: String
        let isSecure: Bool
        @Binding var isFocused: Bool

        func makeCoordinator() -> Coordinator {
            Coordinator(self)
        }

        func makeUIView(context: Context) -> UITextField {
            let field = UITextField()
            field.delegate = context.coordinator
            field.font = .preferredFont(forTextStyle: .body)
            field.adjustsFontForContentSizeCategory = true
            field.textContentType = .password
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.spellCheckingType = .no
            field.smartQuotesType = .no
            field.smartDashesType = .no
            field.accessibilityLabel = String(localized: .password)
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            field.addTarget(
                context.coordinator, action: #selector(Coordinator.textChanged), for: .editingChanged)
            return field
        }

        func updateUIView(_ field: UITextField, context: Context) {
            context.coordinator.parent = self
            field.isEnabled = context.environment.isEnabled
            if field.text != text {
                field.text = text
            }
            if field.isSecureTextEntry != isSecure {
                let selection = field.selectedTextRange.map {
                    (
                        start: field.offset(from: field.beginningOfDocument, to: $0.start),
                        end: field.offset(from: field.beginningOfDocument, to: $0.end)
                    )
                }
                field.isSecureTextEntry = isSecure
                // Reset UIKit's secure-entry buffer so the next character keeps the existing text.
                context.coordinator.isUpdatingText = true
                field.text = nil
                let undoManager = field.undoManager
                undoManager?.disableUndoRegistration()
                field.insertText(text)
                undoManager?.enableUndoRegistration()
                field.clearsOnInsertion = false
                if let selection,
                    let start = field.position(from: field.beginningOfDocument, offset: selection.start),
                    let end = field.position(from: field.beginningOfDocument, offset: selection.end)
                {
                    field.selectedTextRange = field.textRange(from: start, to: end)
                }
                context.coordinator.isUpdatingText = false
            }
            if isFocused && !field.isFirstResponder {
                field.becomeFirstResponder()
            } else if !isFocused && field.isFirstResponder {
                field.resignFirstResponder()
            }
        }

        final class Coordinator: NSObject, UITextFieldDelegate {
            var parent: PasswordTextField
            var isUpdatingText = false

            init(_ parent: PasswordTextField) {
                self.parent = parent
            }

            @objc func textChanged(_ field: UITextField) {
                guard !isUpdatingText else {
                    return
                }
                parent.text = field.text ?? ""
            }

            func textFieldDidBeginEditing(_ textField: UITextField) {
                textField.clearsOnInsertion = false
                if !parent.isFocused {
                    parent.isFocused = true
                }
            }

            func textFieldDidEndEditing(_ textField: UITextField) {
                if parent.isFocused {
                    parent.isFocused = false
                }
            }
        }
    }
#endif
