import Markdown
import SwiftUI

struct MarkdownDocumentView: View {
    let markdown: String
    var style: MarkdownDocumentStyle = .document

    private var blocks: [Markup] {
        Array(Document(parsing: normalizedMarkdown).children)
    }

    private var normalizedMarkdown: String {
        markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: style.blockSpacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(markup: block, style: style)
            }
        }
    }
}

struct MarkdownDocumentStyle {
    var blockSpacing: CGFloat
    var listSpacing: CGFloat
    var listItemSpacing: CGFloat
    var paragraphFont: Font
    var paragraphLineSpacing: CGFloat
    var codeFont: Font
    var headingFont: (Int) -> Font
    var foregroundColor: Color
    var secondaryColor: Color
    var linkColor: Color
    var codeBackgroundColor: Color

    static let document = MarkdownDocumentStyle(
        blockSpacing: 10,
        listSpacing: 7,
        listItemSpacing: 7,
        paragraphFont: .body,
        paragraphLineSpacing: 4,
        codeFont: .system(.body, design: .monospaced),
        headingFont: { level in
            switch level {
            case 1:
                return .title2.weight(.semibold)
            case 2:
                return .title3.weight(.semibold)
            default:
                return .headline
            }
        },
        foregroundColor: .primary,
        secondaryColor: .secondary,
        linkColor: .accentColor,
        codeBackgroundColor: .secondary.opacity(0.12)
    )

    static let chat = MarkdownDocumentStyle(
        blockSpacing: 6,
        listSpacing: 4,
        listItemSpacing: 4,
        paragraphFont: .system(size: 12.5, weight: .regular),
        paragraphLineSpacing: 2,
        codeFont: .system(size: 12, weight: .regular, design: .monospaced),
        headingFont: { level in
            switch level {
            case 1, 2:
                return .system(size: 13, weight: .semibold)
            default:
                return .system(size: 12.5, weight: .semibold)
            }
        },
        foregroundColor: .white.opacity(0.86),
        secondaryColor: .white.opacity(0.52),
        linkColor: .white.opacity(0.9),
        codeBackgroundColor: .white.opacity(0.08)
    )
}

private struct MarkdownBlockView: View {
    let markup: Markup
    let style: MarkdownDocumentStyle

    var body: some View {
        blockView
    }

    @ViewBuilder
    private var blockView: some View {
        if let heading = markup as? Heading {
            SwiftUI.Text(MarkdownInlineRenderer.attributedText(from: heading, style: style))
                .font(style.headingFont(heading.level))
                .foregroundStyle(style.foregroundColor)
                .lineLimit(nil)
                .textSelection(.enabled)
                .padding(.top, heading.level <= 2 ? 4 : 2)
        } else if let paragraph = markup as? Paragraph {
            SwiftUI.Text(MarkdownInlineRenderer.attributedText(from: paragraph, style: style))
                .font(style.paragraphFont)
                .foregroundStyle(style.foregroundColor)
                .lineSpacing(style.paragraphLineSpacing)
                .textSelection(.enabled)
        } else if let unorderedList = markup as? UnorderedList {
            MarkdownListView(list: unorderedList, isOrdered: false, style: style)
        } else if let orderedList = markup as? OrderedList {
            MarkdownListView(list: orderedList, isOrdered: true, startIndex: Int(orderedList.startIndex), style: style)
        } else if let blockQuote = markup as? BlockQuote {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(blockQuote.children.enumerated()), id: \.offset) { _, child in
                    MarkdownBlockView(markup: child, style: style)
                }
            }
            .padding(.leading, 12)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(style.secondaryColor.opacity(0.35))
                    .frame(width: 3)
            }
        } else if let codeBlock = markup as? CodeBlock {
            SwiftUI.Text(codeBlock.code)
                .font(style.codeFont)
                .foregroundStyle(style.foregroundColor)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(style.codeBackgroundColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else if markup is ThematicBreak {
            Divider()
        } else {
            SwiftUI.Text(markup.format())
                .font(style.paragraphFont)
                .foregroundStyle(style.foregroundColor)
                .lineSpacing(style.paragraphLineSpacing)
                .textSelection(.enabled)
        }
    }
}

private struct MarkdownListView: View {
    let list: Markup
    let isOrdered: Bool
    var startIndex = 1
    let style: MarkdownDocumentStyle

    private var items: [ListItem] {
        list.children.compactMap { $0 as? ListItem }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: style.listSpacing) {
            ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    SwiftUI.Text(isOrdered ? "\(startIndex + offset)." : "•")
                        .font(style.paragraphFont.weight(.semibold))
                        .foregroundStyle(style.secondaryColor)
                        .frame(width: isOrdered ? 28 : 14, alignment: .trailing)

                    VStack(alignment: .leading, spacing: style.listItemSpacing) {
                        ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in
                            MarkdownBlockView(markup: child, style: style)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private enum MarkdownInlineRenderer {
    static func attributedText(from container: InlineContainer, style: MarkdownDocumentStyle) -> AttributedString {
        attributedText(from: container.children, style: style)
    }

    private static func attributedText(from children: MarkupChildren, style: MarkdownDocumentStyle) -> AttributedString {
        var result = AttributedString()

        for child in children {
            result.append(attributedText(from: child, style: style))
        }

        return result
    }

    private static func attributedText(from markup: Markup, style: MarkdownDocumentStyle) -> AttributedString {
        switch markup {
        case let text as Markdown.Text:
            return AttributedString(text.string)
        case let softBreak as SoftBreak:
            return AttributedString(softBreak.plainText)
        case let lineBreak as LineBreak:
            return AttributedString(lineBreak.plainText)
        case let inlineCode as InlineCode:
            var value = AttributedString(inlineCode.code)
            value.font = style.codeFont
            value.foregroundColor = style.secondaryColor
            return value
        case let strong as Strong:
            var value = attributedText(from: strong.children, style: style)
            value.font = style.paragraphFont.bold()
            return value
        case let emphasis as Emphasis:
            var value = attributedText(from: emphasis.children, style: style)
            value.font = style.paragraphFont.italic()
            return value
        case let link as Markdown.Link:
            var value = attributedText(from: link.children, style: style)
            value.foregroundColor = style.linkColor
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
