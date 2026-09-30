import Foundation

/// Inline emphasis inside one translatable sentence. Translators see the whole sentence with
/// `**bold**` markers ("Drag a URL or **.torrent** file here") and can move the emphasis with the
/// word, instead of receiving fragments like "Drag a URL or " and " file here".
enum MarkdownText {
    static func attributed(_ localized: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: localized, options: options)) ?? AttributedString(localized)
    }
}
