import Foundation

struct ObsidianBasketItem: Identifiable {
    var id = UUID().uuidString
    let lineIndex: Int
    let title: String
    let isCompleted: Bool
    let moveUpDestination: Int?
    let moveDownDestination: Int?
}

struct MarkdownList {
    var text: String

    private struct TaskKey: Hashable {
        let title: String
        let context: [String]
        var occurrence = 0
    }

    private struct MergeLine: Equatable {
        enum Content: Equatable {
            case text(String)
            case item(TaskKey)
        }

        let content: Content
        let ending: String

        func matches(_ line: (key: TaskKey?, text: String)) -> Bool {
            switch content {
            case .item(let key):
                return line.key == key
            case .text(let text):
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && line.key == nil && line.text == text + ending
            }
        }
    }

    private struct LineEdit {
        let range: Range<Int>
        let replacement: [MergeLine]
        let isLocal: Bool
    }

    static func merged(base: String, local: String, remote: String, localIsNewer: Bool) throws -> String {
        if local == remote || remote == base { return local }
        if local == base { return remote }

        let originalHeader = MarkdownList(text: base).frontmatter
        let preferredText = localIsNewer ? local : remote
        let otherText = localIsNewer ? remote : local
        let preferredHeader = MarkdownList(text: preferredText).frontmatter
        let otherHeader = MarkdownList(text: otherText).frontmatter
        guard preferredHeader == otherHeader || preferredHeader == originalHeader
            || otherHeader == originalHeader
        else {
            throw ObsidianBasketError.message(String(localized: .conflictingNoteText))
        }
        let header = preferredHeader == originalHeader ? otherHeader : preferredHeader
        let original = MarkdownList(text: String(base.dropFirst(originalHeader.count)))
        let preferred = MarkdownList(text: String(preferredText.dropFirst(preferredHeader.count)))
        let other = MarkdownList(text: String(otherText.dropFirst(otherHeader.count)))
        let parsedTasks = zip(
            [original, preferred, other], [originalHeader, preferredHeader, otherHeader]
        ).map { document, header in
            document.parse(recognizingFrontmatter: header.isEmpty).tasks
        }
        var duplicatedTitles = Set(parsedTasks.flatMap { tasks in
            Dictionary(grouping: tasks, by: { $0.key.title }).filter { $0.value.count > 1 }.keys
        })
        let originalTitles = Set(parsedTasks[0].map { $0.key.title })
        let additions = Dictionary(grouping: parsedTasks.dropFirst().flatMap { $0 }) { $0.key.title }
        for (title, tasks) in additions where !originalTitles.contains(title) {
            if Set(tasks.map { $0.key.context }).count > 1 {
                duplicatedTitles.insert(title)
            }
        }
        let taskSets = parsedTasks.map { tasks in
            tasks.map { task in
                var task = task
                if !duplicatedTitles.contains(task.key.title) {
                    task.key = TaskKey(title: task.key.title, context: [])
                }
                return task
            }
        }
        let originalTasks = taskSets[0]
        let preferredTasks = taskSets[1]
        let otherTasks = taskSets[2]
        let baseline = original.mergeLines(matching: originalTasks)
        let preferredMergeLines = preferred.mergeLines(matching: preferredTasks)
        let otherMergeLines = other.mergeLines(matching: otherTasks)
        let versions = [baseline, preferredMergeLines, otherMergeLines]
        let orders = taskSets.map { $0.map(\.key) }
        let changedTaskBlocks = orders.dropFirst().map { order in
            let originalKeys = Set(orders[0])
            let updatedKeys = Set(order)
            let removed = originalTasks.filter { !updatedKeys.contains($0.key) }
            let reordered = orders[0].filter { updatedKeys.contains($0) }
                != order.filter { originalKeys.contains($0) }
            let replaced = !removed.isEmpty && !updatedKeys.isSubset(of: originalKeys)
            return reordered || replaced || removed.contains { $0.block.count > 1 }
        }
        let prose = versions.map { lines in
            lines.filter {
                if case .text = $0.content { return true }
                return false
            }
        }
        // A line diff cannot reliably attach an independent prose edit to a moved task block.
        // Renamed or removed blocks can lose their anchors in the same way.
        if changedTaskBlocks[0] && prose[0] != prose[2]
            || changedTaskBlocks[1] && prose[0] != prose[1]
        {
            throw ObsidianBasketError.message(String(localized: .conflictingNoteText))
        }
        for title in duplicatedTitles {
            let matching = taskSets.map { tasks in
                tasks.filter { $0.key.title == title }
            }
            let originalContexts = Set(matching[0].map { $0.key.context })
            for tasks in matching.dropFirst() where tasks.count >= matching[0].count {
                guard originalContexts.isSubset(of: Set(tasks.map { $0.key.context })) else {
                    throw ObsidianBasketError.message(String(localized: .conflictingNoteSections))
                }
            }
        }
        let preferredLines = preferred.text.components(separatedBy: "\n")
        let otherLines = other.text.components(separatedBy: "\n")
        let counts = [originalTasks, preferredTasks, otherTasks].map { tasks in
            Dictionary(grouping: tasks) { task in
                var key = task.key
                key.occurrence = 0
                return key
            }.mapValues(\.count)
        }
        // Deleting or moving identical task blocks leaves no reliable way to match their occurrences.
        for key in Set(counts.flatMap(\.keys)) where counts.contains(where: { $0[key, default: 0] > 1 }) {
            if counts[0][key, default: 0] == 0,
                counts[1][key, default: 0] == 0 || counts[2][key, default: 0] == 0
            {
                continue
            }
            guard counts.allSatisfy({ $0[key, default: 0] == counts[0][key, default: 0] }) else {
                throw ObsidianBasketError.message(String(localized: .conflictingNoteSections))
            }
            let blocks = zip([original, preferred, other], taskSets).map { document, tasks in
                let lines = document.text.components(separatedBy: "\n")
                return tasks.filter { $0.key.title == key.title && $0.key.context == key.context }.map {
                    Array(lines[$0.block])
                }
            }
            guard blocks[0] == blocks[1], blocks[0] == blocks[2] else {
                throw ObsidianBasketError.message(String(localized: .conflictingNoteSections))
            }
        }
        var seen: Set<TaskKey> = []
        var itemLines: [TaskKey: String] = [:]
        var itemOrder: [TaskKey] = []
        for task in preferredTasks + otherTasks {
            let key = task.key
            guard seen.insert(key).inserted else { continue }
            let baseline = originalTasks.first { $0.key == key }
            let newer = preferredTasks.first { $0.key == key }
            let older = otherTasks.first { $0.key == key }
            if let baseline {
                if newer == nil { continue }
                if older == nil, newer?.title == baseline.title,
                    newer?.isCompleted == baseline.isCompleted
                {
                    continue
                }
            }
            let selected: TaskLine
            let source: [String]
            let completed: Bool
            if let newer, let older {
                if newer.title == baseline?.title, older.title != newer.title {
                    selected = older
                    source = otherLines
                } else {
                    selected = newer
                    source = preferredLines
                }
                completed = newer.isCompleted == baseline?.isCompleted ? older.isCompleted : newer.isCompleted
            } else if let newer {
                selected = newer
                source = preferredLines
                completed = newer.isCompleted
            } else if let older {
                selected = older
                source = otherLines
                completed = older.isCompleted
            } else {
                continue
            }
            var line = source[selected.index]
            line.replaceSubrange(selected.marker, with: completed ? "x" : " ")
            if line.hasSuffix("\r") { line.removeLast() }
            itemLines[key] = line
            itemOrder.append(key)
        }

        // Item names anchor the surrounding Markdown while their contents are reconciled separately.
        // Keep each slot's position and line ending.
        let edits =
            (lineEdits(from: baseline, to: preferredMergeLines, isLocal: localIsNewer)
            + lineEdits(from: baseline, to: otherMergeLines, isLocal: !localIsNewer)).sorted {
                if $0.range.lowerBound == $1.range.lowerBound {
                    return $0.range.upperBound < $1.range.upperBound
                }
                return $0.range.lowerBound < $1.range.lowerBound
            }
        var merged: [MergeLine] = []
        var position = 0
        var index = 0
        while index < edits.count {
            var group = [edits[index]]
            var range = edits[index].range
            index += 1
            while index < edits.count,
                edits[index].range.lowerBound < range.upperBound || edits[index].range == range
            {
                group.append(edits[index])
                range = range.lowerBound..<max(range.upperBound, edits[index].range.upperBound)
                index += 1
            }
            merged.append(contentsOf: baseline[position..<range.lowerBound])
            let preferredEdits = group.filter { $0.isLocal == localIsNewer }
            let otherEdits = group.filter { $0.isLocal != localIsNewer }
            let preferredLines = applying(preferredEdits, to: baseline, within: range)
            let otherLines = applying(otherEdits, to: baseline, within: range)
            if preferredEdits.isEmpty {
                merged.append(contentsOf: otherLines)
            } else if otherEdits.isEmpty || preferredLines == otherLines {
                merged.append(contentsOf: preferredLines)
            } else if range.isEmpty {
                merged.append(contentsOf: preferredLines)
                merged.append(contentsOf: otherLines)
            } else if preferredEdits.allSatisfy({ $0.range.isEmpty }) {
                merged.append(contentsOf: otherLines)
                merged.append(contentsOf: preferredEdits.flatMap(\.replacement))
            } else {
                let ambiguousProse = group.contains { edit in
                    guard !edit.range.isEmpty, !edit.replacement.isEmpty,
                        edit.range.count != edit.replacement.count
                    else { return false }
                    return (Array(baseline[edit.range]) + edit.replacement).contains {
                        if case .text = $0.content { return true }
                        return false
                    }
                }
                guard !ambiguousProse else {
                    throw ObsidianBasketError.message(
                        String(localized: .conflictingNoteText)
                    )
                }
                merged.append(contentsOf: preferredLines)
                merged.append(contentsOf: otherEdits.filter { $0.range.isEmpty }.flatMap(\.replacement))
            }
            position = range.upperBound
        }
        merged.append(contentsOf: baseline[position...])

        var output: [(key: TaskKey?, text: String)] = []
        var emitted: Set<TaskKey> = []
        for line in merged {
            switch line.content {
            case .text(let text):
                output.append((nil, text + line.ending))
            case .item(let key):
                if let text = itemLines[key], emitted.insert(key).inserted {
                    output.append((key, text + line.ending))
                }
            }
        }
        let newline = preferred.text.contains("\r\n") ? "\r\n" : "\n"
        for key in itemOrder where !emitted.contains(key) {
            guard let line = itemLines[key] else { continue }
            let source =
                preferredTasks.contains { $0.key == key }
                ? preferredMergeLines : otherMergeLines
            guard let sourceIndex = source.firstIndex(where: { $0.content == .item(key) }) else { continue }
            func outputIndex(for index: Int) throws -> Int? {
                let anchor = source[index]
                let matches = output.indices.filter { anchor.matches(output[$0]) }
                guard !matches.isEmpty else { return nil }
                if case .item = anchor.content { return matches.first }
                guard source.filter({ $0 == anchor }).count == matches.count else {
                    throw ObsidianBasketError.message(
                        String(localized: .conflictingNoteSections)
                    )
                }
                let occurrence = source[..<index].filter { $0 == anchor }.count
                return matches[occurrence]
            }
            var next: Int?
            for index in source.indices.dropFirst(sourceIndex + 1) {
                if let match = try outputIndex(for: index) {
                    next = match
                    break
                }
            }
            var previous: Int?
            if next == nil {
                for index in source.indices.prefix(sourceIndex).reversed() {
                    if let match = try outputIndex(for: index) {
                        previous = match
                        break
                    }
                }
            }
            let insertion =
                next ?? previous.map { $0 + 1 }
                ?? output.lastIndex(where: { $0.key != nil }).map { $0 + 1 } ?? output.count
            output.insert((key, line + newline), at: insertion)
            emitted.insert(key)
        }
        let body = output.enumerated().map { index, line in
            line.text + (index < output.count - 1 && line.text.last?.isNewline != true ? newline : "")
        }.joined()
        return header + (!header.isEmpty && header.last?.isNewline != true && !body.isEmpty ? newline : "")
            + body
    }

    private var frontmatter: String {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
            let closing = lines.indices.dropFirst().first(where: {
                let line = lines[$0].trimmingCharacters(in: .whitespacesAndNewlines)
                return line == "---" || line == "..."
            })
        else { return "" }
        return lines.prefix(closing + 1).joined(separator: "\n") + (closing < lines.count - 1 ? "\n" : "")
    }

    private func mergeLines(matching tasks: [TaskLine]) -> [MergeLine] {
        let lines = text.components(separatedBy: "\n")
        return lines.enumerated().compactMap { index, line in
            if index == lines.count - 1 && line.isEmpty { return nil }
            let hasNewline = index < lines.count - 1
            let ending = hasNewline ? (line.hasSuffix("\r") ? "\r\n" : "\n") : ""
            let content = hasNewline && line.hasSuffix("\r") ? String(line.dropLast()) : line
            let task = tasks.first { $0.index == index }
            return MergeLine(
                content: task.map { .item($0.key) } ?? .text(content),
                ending: ending)
        }
    }

    private static func lineEdits(from baseline: [MergeLine], to updated: [MergeLine], isLocal: Bool)
        -> [LineEdit]
    {
        var removals: Set<Int> = []
        var insertions: Set<Int> = []
        // Task contents are reconciled separately. Compare their slots here so a task edit
        // doesn't hide an independent change to surrounding prose.
        for change in updated.difference(
            from: baseline,
            by: { original, changed in
                if case .item = original.content, case .item = changed.content {
                    return true
                }
                return original == changed
            })
        {
            switch change {
            case .remove(let offset, _, _): removals.insert(offset)
            case .insert(let offset, _, _): insertions.insert(offset)
            }
        }
        var edits: [LineEdit] = []
        var originalIndex = 0
        var updatedIndex = 0
        while originalIndex < baseline.count || updatedIndex < updated.count {
            if removals.contains(originalIndex) || insertions.contains(updatedIndex) {
                let start = originalIndex
                let updatedStart = updatedIndex
                while removals.contains(originalIndex) || insertions.contains(updatedIndex) {
                    if removals.contains(originalIndex) { originalIndex += 1 }
                    if insertions.contains(updatedIndex) { updatedIndex += 1 }
                }
                if originalIndex - start == updatedIndex - updatedStart || updatedIndex == updatedStart {
                    for oldIndex in start..<originalIndex {
                        let replacement =
                            updatedIndex == updatedStart
                            ? [] : [updated[updatedStart + oldIndex - start]]
                        edits.append(
                            LineEdit(
                                range: oldIndex..<(oldIndex + 1), replacement: replacement,
                                isLocal: isLocal))
                    }
                } else {
                    edits.append(
                        LineEdit(
                            range: start..<originalIndex,
                            replacement: Array(updated[updatedStart..<updatedIndex]),
                            isLocal: isLocal))
                }
            } else {
                if baseline[originalIndex] != updated[updatedIndex] {
                    edits.append(
                        LineEdit(
                            range: originalIndex..<(originalIndex + 1),
                            replacement: [updated[updatedIndex]], isLocal: isLocal))
                }
                originalIndex += 1
                updatedIndex += 1
            }
        }
        return edits
    }

    private static func applying(
        _ edits: [LineEdit], to lines: [MergeLine], within range: Range<Int>
    ) -> [MergeLine] {
        var result = Array(lines[range])
        for edit in edits.reversed() {
            let start = edit.range.lowerBound - range.lowerBound
            let end = edit.range.upperBound - range.lowerBound
            result.replaceSubrange(start..<end, with: edit.replacement)
        }
        return result
    }

    private struct TaskLine {
        var key: TaskKey
        var index: Int
        var marker: Range<String.Index>
        var titleRange: Range<String.Index>
        var title: String
        var isCompleted: Bool
        var indentation: Int
        var parent: Int?
        var root: Int
        var block: Range<Int>
    }

    var items: [ObsidianBasketItem] {
        let tasks = parse().tasks
        return tasks.enumerated().map { offset, task in
            let previous = tasks.indices.last(where: { $0 < offset && tasks[$0].parent == task.parent })
            let next = tasks.indices.first(where: { $0 > offset && tasks[$0].parent == task.parent })
            let moveDownDestination = next.map { next in
                tasks.firstIndex(where: { $0.index >= tasks[next].block.upperBound }) ?? tasks.count
            }
            return ObsidianBasketItem(
                lineIndex: task.index,
                title: task.title, isCompleted: task.isCompleted,
                moveUpDestination: previous, moveDownDestination: moveDownDestination
            )
        }
    }

    private func parse(recognizingFrontmatter: Bool = true) -> (tasks: [TaskLine], canAppend: Bool) {
        let lines = text.components(separatedBy: "\n")
        var blockIndentations = lines.map { indentation(of: $0) }
        var fence: Character?
        var fenceLength = 0
        var fenceIndentation = 0
        var frontmatter = false
        var commentEnd: String?
        var commentIndentation = 0
        var lists: [(index: Int, contentIndentation: Int, title: String)] = []
        var headings: [(level: Int, title: String)] = []
        var occurrences: [TaskKey: Int] = [:]
        var listParents: [Int: Int] = [:]
        var tasks: [TaskLine] = []
        let listPattern = /[ \t]*(?:[-*+]|[0-9]{1,9}[.)])[ \t]+([^\r\n]*)\r?/
        let taskPattern = /[ \t]*[-*+][ \t]+\[([ xX])\][ \t]+([^\r\n]*?)[ \t]*\r?/
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let indentation = indentation(of: line)
            if recognizingFrontmatter && index == 0 && trimmed == "---" {
                frontmatter = true
                continue
            }
            if frontmatter {
                if trimmed == "---" || trimmed == "..." {
                    frontmatter = false
                }
                continue
            }
            if let currentFence = fence {
                blockIndentations[index] = max(indentation, fenceIndentation)
                let count = trimmed.prefix(while: { $0 == currentFence }).count
                if count >= fenceLength && indentation <= fenceIndentation + 3
                    && trimmed.dropFirst(count).allSatisfy(\.isWhitespace)
                {
                    fence = nil
                }
                continue
            }
            if trimmed.isEmpty { continue }
            if commentEnd == nil {
                while let last = lists.last, indentation < last.contentIndentation {
                    lists.removeLast()
                }
            } else {
                blockIndentations[index] = max(indentation, commentIndentation)
            }
            let contentIndentation = lists.last?.contentIndentation ?? 0
            guard commentEnd != nil || indentation < contentIndentation + 4 else { continue }
            if commentEnd == nil, let marker = trimmed.first, marker == "`" || marker == "~" {
                let count = trimmed.prefix(while: { $0 == marker }).count
                if count >= 3 {
                    fence = marker
                    fenceLength = count
                    fenceIndentation = indentation
                    continue
                }
            }
            let startedInComment = commentEnd != nil
            var position = line.startIndex
            while position < line.endIndex {
                if let end = commentEnd {
                    guard let closing = line.range(of: end, range: position..<line.endIndex) else {
                        break
                    }
                    position = closing.upperBound
                    commentEnd = nil
                } else if line[position] == "\\" {
                    position = line.index(after: position)
                    if position < line.endIndex { position = line.index(after: position) }
                } else if line[position] == "`" {
                    let count = line[position...].prefix(while: { $0 == "`" }).count
                    position = line.index(position, offsetBy: count)
                    if let closing = line.range(
                        of: String(repeating: "`", count: count), range: position..<line.endIndex
                    ) {
                        position = closing.upperBound
                    }
                } else if line[position...].hasPrefix("<!--") {
                    position = line.index(position, offsetBy: 4)
                    commentEnd = "-->"
                    commentIndentation = indentation + 1
                } else if line[position...].hasPrefix("%%") {
                    position = line.index(position, offsetBy: 2)
                    commentEnd = "%%"
                    commentIndentation = indentation + 1
                } else {
                    position = line.index(after: position)
                }
            }
            guard !startedInComment else { continue }
            if let heading = line.wholeMatch(of: /[ \t]{0,3}(#{1,6})[ \t]+(.+?)\r?/) {
                let level = heading.1.count
                headings.removeAll { $0.level >= level }
                headings.append((level, String(heading.2)))
            }
            if let match = line.wholeMatch(of: listPattern) {
                if let task = line.wholeMatch(of: taskPattern) {
                    var key = TaskKey(
                        title: Self.normalizedTitle(String(task.2)).lowercased(),
                        context: headings.map { "\($0.level):\($0.title)" } + lists.map { "-\($0.title)" })
                    let occurrence = occurrences[key, default: 0]
                    occurrences[key] = occurrence + 1
                    key.occurrence = occurrence
                    tasks.append(
                        TaskLine(
                            key: key,
                            index: index,
                            marker: task.1.startIndex..<task.1.endIndex,
                            titleRange: task.2.startIndex..<task.2.endIndex,
                            title: String(task.2),
                            isCompleted: task.1 != " ",
                            indentation: indentation,
                            parent: lists.last?.index,
                            root: lists.first?.index ?? index,
                            block: index..<(index + 1)
                        ))
                }
                var contentColumns = 0
                for character in line[..<match.1.startIndex] {
                    contentColumns += character == "\t" ? 4 - contentColumns % 4 : 1
                }
                listParents[index] = lists.last?.index ?? -1
                let title = if let task = tasks.last, task.index == index {
                    task.title
                } else {
                    String(match.1)
                }
                lists.append((index, contentColumns, Self.normalizedTitle(title).lowercased()))
            }
        }
        for taskIndex in tasks.indices {
            let task = tasks[taskIndex]
            var end = task.index + 1
            for index in (task.index + 1)..<lines.count {
                if lines[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continue
                }
                guard blockIndentations[index] > task.indentation,
                    listParents[index] != (task.parent ?? -1)
                else { break }
                end = index + 1
            }
            tasks[taskIndex].block = task.index..<end
        }
        return (tasks, fence == nil && !frontmatter && commentEnd == nil)
    }

    private func indentation(of line: String) -> Int {
        var columns = 0
        for character in line {
            if character == " " {
                columns += 1
            } else if character == "\t" {
                columns += 4 - columns % 4
            } else {
                break
            }
        }
        return columns
    }

    mutating func toggle(_ item: ObsidianBasketItem) {
        guard let entry = parse().tasks.first(where: { $0.index == item.lineIndex }) else { return }
        var lines = text.components(separatedBy: "\n")
        lines[item.lineIndex].replaceSubrange(entry.marker, with: item.isCompleted ? " " : "x")
        text = lines.joined(separator: "\n")
    }

    mutating func rename(_ item: ObsidianBasketItem, to title: String) throws {
        let title = Self.normalizedTitle(title)
        guard !title.isEmpty else {
            throw ObsidianBasketError.message(String(localized: .itemNameRequired))
        }
        guard let entry = parse().tasks.first(where: { $0.index == item.lineIndex }) else {
            throw ObsidianBasketError.message(String(localized: .itemChangedWhileEditing))
        }
        var lines = text.components(separatedBy: "\n")
        lines[item.lineIndex].replaceSubrange(entry.titleRange, with: title)
        text = lines.joined(separator: "\n")
    }

    mutating func add(_ title: String) throws {
        let title = Self.normalizedTitle(title)
        guard !title.isEmpty else { return }
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let parsed = parse()
        guard parsed.canAppend else {
            throw ObsidianBasketError.message(
                String(localized: .unfinishedNoteSection)
            )
        }
        if let lastTask = parsed.tasks.last {
            let last = parsed.tasks.first(where: { $0.index == lastTask.root }) ?? lastTask
            var lines = text.components(separatedBy: "\n")
            let insertion = last.block.upperBound
            let prefix = lines[last.index].prefix(while: { $0 == " " || $0 == "\t" })
            if insertion == lines.count {
                if newline == "\r\n" { lines[insertion - 1] += "\r" }
                lines.append("\(prefix)- [ ] \(title)")
            } else {
                lines.insert("\(prefix)- [ ] \(title)" + (newline == "\r\n" ? "\r" : ""), at: insertion)
            }
            text = lines.joined(separator: "\n")
        } else {
            if !text.isEmpty && !text.hasSuffix("\n") {
                text += newline
            }
            text += "- [ ] \(title)\(newline)"
        }
    }

    static func normalizedTitle(_ title: String) -> String {
        title.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func remove(at offsets: IndexSet) {
        let tasks = parse().tasks
        let removed = Set(offsets.map { tasks[$0].index })
        let lines = text.components(separatedBy: "\n")
        text = lines.enumerated()
            .filter { !removed.contains($0.offset) }
            .map { index, line in line + (index < lines.count - 1 ? "\n" : "") }
            .joined()
    }

    mutating func move(from offsets: IndexSet, to destination: Int) throws {
        let tasks = parse().tasks
        guard !offsets.isEmpty else { return }
        guard offsets.allSatisfy({ tasks.indices.contains($0) }), (0...tasks.count).contains(destination),
            let first = offsets.first
        else {
            throw ObsidianBasketError.message(String(localized: .itemChangedWhileMoving))
        }
        let parent = tasks[first].parent
        guard offsets.allSatisfy({ tasks[$0].parent == parent }) else {
            throw ObsidianBasketError.message(
                String(localized: .moveWithinSameList))
        }
        let siblings = tasks.filter { $0.parent == parent }
        let removed = Set(offsets.map { tasks[$0].index })
        let siblingsEnd =
            tasks.last(where: { $0.parent == parent })?.block.upperBound
            ?? tasks[first].block.upperBound
        let endOffset = tasks.firstIndex(where: { $0.index >= siblingsEnd }) ?? tasks.count
        let insertion: Int
        if destination == endOffset {
            insertion = siblings.count
        } else if destination < tasks.count {
            if removed.contains(tasks[destination].index) { return }
            guard let index = siblings.firstIndex(where: { $0.index == tasks[destination].index }) else {
                throw ObsidianBasketError.message(
                    String(localized: .moveWithinSameList))
            }
            insertion = index
        } else {
            throw ObsidianBasketError.message(
                String(localized: .moveWithinSameList))
        }
        let moved = siblings.indices.filter { removed.contains(siblings[$0].index) }
        var reordered = siblings.indices.filter { !removed.contains(siblings[$0].index) }
        reordered.insert(contentsOf: moved, at: insertion - moved.filter { $0 < insertion }.count)
        let lines = text.components(separatedBy: "\n")
        var updated = lines

        // Move descendants and indented notes with their parent. Keep each slot's final line
        // ending so moving the final block cannot create a bare carriage return.
        for (destination, source) in zip(siblings, reordered).reversed() {
            var block = Array(lines[siblings[source].block])
            let last = block.count - 1
            if block[last].hasSuffix("\r") { block[last].removeLast() }
            if lines[destination.block.upperBound - 1].hasSuffix("\r") { block[last] += "\r" }
            updated.replaceSubrange(destination.block, with: block)
        }
        text = updated.joined(separator: "\n")
    }
}
