#if os(macOS)
    import AppKit
    import SwiftUI

    struct ItemNameTextField: NSViewRepresentable {
        @Binding var text: String
        @Binding var focusedItem: String?
        let itemID: String
        let isCompleted: Bool

        private var isFocused: Bool { focusedItem == itemID }

        func makeNSView(context: Context) -> Field {
            let field = Field()
            field.cell = Cell()
            field.isEditable = true
            field.isSelectable = true
            field.isBordered = false
            field.isBezeled = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.font = .preferredFont(forTextStyle: .body)
            field.usesSingleLineMode = true
            field.lineBreakMode = .byTruncatingTail
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            // The list receives initial clicks itself, so a recognizer attached to the field misses them.
            field.eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [
                .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            ]) {
                [weak field] event in
                field?.handleMouseEvent(event)
                return event
            }
            return field
        }

        static func dismantleNSView(_ field: Field, coordinator: ()) {
            if let eventMonitor = field.eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }
        }

        func updateNSView(_ field: Field, context: Context) {
            field.onTextChange = { text = $0 }
            field.onFocusChange = { focused in
                // Ending editing in the previous row must not clear focus from the newly focused row.
                if isFocused != focused {
                    focusedItem = focused ? itemID : nil
                }
            }
            field.isEnabled = context.environment.isEnabled
            field.textColor = isCompleted && !isFocused ? .clear : .labelColor
            // Reassigning unchanged text can reset the active editor's selection during view updates.
            if field.stringValue != text {
                field.stringValue = text
            }
            if !isFocused && field.currentEditor() != nil {
                field.window?.makeFirstResponder(nil)
            }
        }

        final class Cell: NSTextFieldCell {
            override func hitTest(for event: NSEvent, in cellFrame: NSRect, of controlView: NSView)
                -> NSCell.HitResult
            {
                guard cellFrame.contains(controlView.convert(event.locationInWindow, from: nil)) else {
                    return []
                }
                // The table delays editable-cell focus and selects all text, even after a drag.
                // Only the active editor uses that path. Initial clicks are handled on mouse-up.
                if let field = controlView as? NSTextField,
                    let editor = field.currentEditor(),
                    editor.bounds.contains(editor.convert(event.locationInWindow, from: nil))
                {
                    return super.hitTest(for: event, in: cellFrame, of: controlView)
                }
                return .contentArea
            }

            // Use the centered drawing rectangle for both editing entry points so focus does not
            // shift the text vertically within the row's larger hit area.
            override func edit(
                withFrame rect: NSRect, in view: NSView, editor: NSText, delegate: Any?, event: NSEvent?
            ) {
                super.edit(
                    withFrame: drawingRect(forBounds: rect), in: view, editor: editor, delegate: delegate,
                    event: event)
            }

            override func select(
                withFrame rect: NSRect, in view: NSView, editor: NSText, delegate: Any?, start: Int,
                length: Int
            ) {
                super.select(
                    withFrame: drawingRect(forBounds: rect), in: view, editor: editor, delegate: delegate,
                    start: start, length: length)
            }

            override func drawingRect(forBounds rect: NSRect) -> NSRect {
                let rect = super.drawingRect(forBounds: rect)
                let height = cellSize.height
                return NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
            }
        }

        final class Field: NSTextField {
            var onTextChange: ((String) -> Void)?
            var onFocusChange: ((Bool) -> Void)?
            var eventMonitor: Any?
            var click: NSEvent?

            // Observe the completed click without replacing the native editor's selection gestures.
            // Keeping the field in place also preserves the second press of a fast double-click.
            func handleMouseEvent(_ event: NSEvent) {
                let point = convert(event.locationInWindow, from: nil)
                // In a list, visibleRect can extend into neighboring controls. Check bounds as well.
                let inside = event.window === window && bounds.contains(point) && visibleRect.contains(point)
                switch event.type {
                case .leftMouseDown:
                    click = nil
                    guard inside, isEnabled else { return }
                    let editor = currentEditor() as? NSTextView
                    let inEditor =
                        editor.map { $0.bounds.contains($0.convert(event.locationInWindow, from: nil)) }
                        ?? false
                    // The first double-click after switching rows can leave only a caret. Handle repeated
                    // clicks, but leave Shift-click to the editor so it extends the existing selection.
                    let nativeSelection = inEditor && event.modifierFlags.contains(.shift)
                    if !nativeSelection && (!inEditor || event.clickCount > 1) {
                        click = event
                    }
                case .leftMouseDragged:
                    if let click {
                        let dx = event.locationInWindow.x - click.locationInWindow.x
                        let dy = event.locationInWindow.y - click.locationInWindow.y
                        // Small pointer movement is common during an ordinary click.
                        if hypot(dx, dy) > 4 {
                            self.click = nil
                        }
                    }
                case .leftMouseUp:
                    defer { self.click = nil }
                    guard let click, inside, isEnabled, let window else { return }
                    window.makeFirstResponder(self)
                    guard let editor = currentEditor() as? NSTextView else { return }
                    let point = editor.convert(click.locationInWindow, from: nil)
                    // The editor spans the row width. Use the drawn text bounds to distinguish text
                    // clicks from padding clicks, which should place the caret at the end.
                    let textRect = editor.firstRect(
                        forCharacterRange: NSRange(location: 0, length: editor.string.utf16.count),
                        actualRange: nil)
                    let onText =
                        editor.bounds.contains(point)
                        && textRect.contains(window.convertPoint(toScreen: click.locationInWindow))
                    let index =
                        onText
                        ? editor.characterIndexForInsertion(at: point) : editor.string.utf16.count
                    // Deferring selection exposes the initial select-all state before moving the caret.
                    editor.setSelectedRange(NSRange(location: index, length: 0))
                    if onText && click.clickCount == 2 {
                        editor.selectWord(nil)
                    } else if onText && click.clickCount >= 3 {
                        editor.selectAll(nil)
                    }
                default:
                    break
                }
            }

            override var intrinsicContentSize: NSSize {
                var size = super.intrinsicContentSize
                // Include the row's vertical padding in the native hit area.
                size.height += 16
                return size
            }

            // Report focus without asking SwiftUI to focus the field again and select its text.
            override func becomeFirstResponder() -> Bool {
                textColor = .labelColor
                let focused = super.becomeFirstResponder()
                if focused {
                    onFocusChange?(true)
                }
                return focused
            }

            override func textDidChange(_ notification: Notification) {
                super.textDidChange(notification)
                onTextChange?(stringValue)
            }

            override func textDidEndEditing(_ notification: Notification) {
                super.textDidEndEditing(notification)
                onFocusChange?(false)
            }
        }
    }
#endif
