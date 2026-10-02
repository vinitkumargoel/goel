import SwiftUI

extension String {
    /// The name with a zero-width break opportunity after each separator (`.` `-` `_` `/` `+`),
    /// so a wrapped file name such as `Cosmos.S01E04.2160p.HDR.mkv` breaks between its parts
    /// instead of mid-word. For display only: never store, copy or speak the result.
    var breakingAtSeparators: String {
        let separators: Set<Character> = [".", "-", "_", "/", "+"]
        var result = ""
        result.reserveCapacity(count + 8)
        var previous: Character?
        for character in self {
            if let previous, separators.contains(previous), !separators.contains(character) {
                result.append("\u{200B}")
            }
            result.append(character)
            previous = character
        }
        return result
    }
}

/// A file name that wraps at its separators, never mid-word, and truncates in the middle (so the
/// extension stays visible). The full name is the tooltip and the accessibility label. Style it
/// like any `Text`:
///
///     FileNameText(task.compactDisplayName, lineLimit: 2).studioFont(.cardTitle)
struct FileNameText: View {
    let name: String
    var lineLimit: Int

    init(_ name: String, lineLimit: Int = 2) {
        self.name = name
        self.lineLimit = lineLimit
    }

    var body: some View {
        Text(verbatim: lineLimit > 1 ? name.breakingAtSeparators : name)
            .lineLimit(lineLimit)
            .truncationMode(.middle)
            .help(name)
            .accessibilityLabel(Text(verbatim: name))
    }
}
