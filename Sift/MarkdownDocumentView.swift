import Markdown
import SwiftUI

struct MarkdownDocumentView: View {
    let markdown: String

    private var blocks: [Markup] {
        Array(Document(parsing: normalizedMarkdown).children)
    }

    private var normalizedMarkdown: String {
        markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(markup: block)
            }
        }
    }
}

private struct MarkdownBlockView: View {
    let markup: Markup

    var body: some View {
        blockView
    }

    @ViewBuilder
    private var blockView: some View {
        if let heading = markup as? Heading {
            SwiftUI.Text(MarkdownInlineRenderer.attributedText(from: heading))
                .font(font(for: heading.level))
                .foregroundStyle(.primary)
                .lineLimit(nil)
                .textSelection(.enabled)
                .padding(.top, heading.level <= 2 ? 4 : 2)
        } else if let paragraph = markup as? Paragraph {
            SwiftUI.Text(MarkdownInlineRenderer.attributedText(from: paragraph))
                .font(.body)
                .lineSpacing(4)
                .textSelection(.enabled)
        } else if let unorderedList = markup as? UnorderedList {
            MarkdownListView(list: unorderedList, isOrdered: false)
        } else if let orderedList = markup as? OrderedList {
            MarkdownListView(list: orderedList, isOrdered: true, startIndex: Int(orderedList.startIndex))
        } else if let blockQuote = markup as? BlockQuote {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(blockQuote.children.enumerated()), id: \.offset) { _, child in
                    MarkdownBlockView(markup: child)
                }
            }
            .padding(.leading, 12)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(.secondary.opacity(0.35))
                    .frame(width: 3)
            }
        } else if let codeBlock = markup as? CodeBlock {
            SwiftUI.Text(codeBlock.code)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else if markup is ThematicBreak {
            Divider()
        } else {
            SwiftUI.Text(markup.format())
                .font(.body)
                .lineSpacing(4)
                .textSelection(.enabled)
        }
    }

    private func font(for level: Int) -> Font {
        switch level {
        case 1:
            return .title2.weight(.semibold)
        case 2:
            return .title3.weight(.semibold)
        default:
            return .headline
        }
    }
}

private struct MarkdownListView: View {
    let list: Markup
    let isOrdered: Bool
    var startIndex = 1

    private var items: [ListItem] {
        list.children.compactMap { $0 as? ListItem }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    SwiftUI.Text(isOrdered ? "\(startIndex + offset)." : "•")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: isOrdered ? 28 : 14, alignment: .trailing)

                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in
                            MarkdownBlockView(markup: child)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private enum MarkdownInlineRenderer {
    static func attributedText(from container: InlineContainer) -> AttributedString {
        attributedText(from: container.children)
    }

    private static func attributedText(from children: MarkupChildren) -> AttributedString {
        var result = AttributedString()

        for child in children {
            result.append(attributedText(from: child))
        }

        return result
    }

    private static func attributedText(from markup: Markup) -> AttributedString {
        switch markup {
        case let text as Markdown.Text:
            return AttributedString(text.string)
        case let softBreak as SoftBreak:
            return AttributedString(softBreak.plainText)
        case let lineBreak as LineBreak:
            return AttributedString(lineBreak.plainText)
        case let inlineCode as InlineCode:
            var value = AttributedString(inlineCode.code)
            value.font = .body.monospaced()
            value.foregroundColor = .secondary
            return value
        case let strong as Strong:
            var value = attributedText(from: strong.children)
            value.font = .body.bold()
            return value
        case let emphasis as Emphasis:
            var value = attributedText(from: emphasis.children)
            value.font = .body.italic()
            return value
        case let link as Markdown.Link:
            var value = attributedText(from: link.children)
            value.foregroundColor = Color.accentColor
            if let destination = link.destination, let url = URL(string: destination) {
                value.link = url
            }
            return value
        case let inline as InlineMarkup:
            return AttributedString(inline.plainText)
        default:
            return AttributedString(markup.format())
        }
    }
}
