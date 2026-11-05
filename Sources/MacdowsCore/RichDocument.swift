import Foundation

/// An HTML file split into the part the WYSIWYG editor changes and what surrounds it, which is saved untouched.
public struct RichDocument: Equatable {
    public var prefix: String
    public var content: String
    public var suffix: String
    /// The file was only a fragment: it is shown with the Balmy styles, which are not saved into it.
    public var isFragment = false

    public static let closing = "\n    </article>\n</body>\n</html>\n"

    public static var blank: RichDocument {
        RichDocument(prefix: balmyTemplate, content: "\n<p><br></p>\n", suffix: closing)
    }

    /// A new document that starts with this content instead of an empty page.
    public static func starter(content: String?) -> RichDocument {
        guard let content, !content.isEmpty else { return blank }
        return RichDocument(prefix: balmyTemplate, content: content, suffix: closing)
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are fixed text, so a failure here is a programming mistake.
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static let articleOpen = regex(#"<article\b[^>]*\bclass\s*=\s*["'][^"']*\btheme-balmy\b[^"']*["'][^>]*>"#)
    private static let bodyOpen = regex(#"<body\b[^>]*>"#)

    public static func parse(_ html: String) -> RichDocument {
        let text = html as NSString
        let whole = NSRange(location: 0, length: text.length)
        if let open = articleOpen.firstMatch(in: html, range: whole) {
            return split(text, after: NSMaxRange(open.range), closingTag: "</article>", missingClose: closing)
        }
        if let open = bodyOpen.firstMatch(in: html, range: whole) {
            return split(text, after: NSMaxRange(open.range), closingTag: "</body>", missingClose: "\n</body>\n</html>\n")
        }
        return RichDocument(prefix: "", content: html, suffix: "", isFragment: true)
    }

    private static func split(_ text: NSString, after start: Int, closingTag: String, missingClose: String) -> RichDocument {
        let rest = NSRange(location: start, length: text.length - start)
        let close = text.range(of: closingTag, options: [.backwards, .caseInsensitive], range: rest)
        let prefix = text.substring(to: start)
        guard close.location != NSNotFound else {
            return RichDocument(prefix: prefix, content: text.substring(from: start), suffix: missingClose)
        }
        return RichDocument(prefix: prefix, content: text.substring(with: NSRange(location: start, length: close.location - start)), suffix: text.substring(from: close.location))
    }

    public func assembled(content newContent: String) -> String {
        prefix + newContent + suffix
    }

    /// What the web view shows.
    public var display: String {
        isFragment ? Self.balmyTemplate + content + Self.closing : prefix + content + suffix
    }

    /// PHP would be mangled by the browser's parser, so such files stay with the code editor.
    public static func containsServerCode(_ html: String) -> Bool {
        html.contains("<?") && html.range(of: #"<\?(php|=|\s)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    public static let balmyTemplate = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Balmy Write Document</title>
        <style>
            body {
                max-width: 800px;
                margin: 0 auto;
                padding: 60px 20px;
                font-family: Georgia, "Times New Roman", serif; /* Default font for page */
                background: #fefcf3;
            }

            /* Scoped Container Styles */
            .theme-balmy {
                display: block;
                width: 100%;
                font-family: Georgia, "Times New Roman", serif;
                color: #3d3929;
                line-height: 1.7;
                font-size: 18px;
            }

            .theme-balmy * { box-sizing: border-box; }

            .theme-balmy h1 {
                font-size: 2.5rem;
                font-weight: 700;
                margin: 0.5em 0 0.5em;
                color: #2C3E50;
                line-height: 1.2;
                word-break: break-word;
            }

            .theme-balmy h2 {
                font-size: 1.8rem;
                font-weight: 600;
                margin: 1.5em 0 0.8em;
                color: #34495E;
                line-height: 1.3;
            }

            .theme-balmy h3 {
                font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
                font-size: 1.4rem;
                font-weight: 500;
                margin: 1.5em 0 0.6em;
                color: #7f8c8d;
                line-height: 1.4;
            }

            .theme-balmy p { margin: 1em 0; line-height: 1.7; }
            .theme-balmy hr { border: none; border-top: 1px solid rgba(0,0,0,0.1); margin: 2em 0; }

            .theme-balmy blockquote {
                border-left: 4px solid #d4a574;
                padding-left: 20px;
                margin: 1.5em 0;
                font-style: italic;
                opacity: 0.9;
                white-space: break-spaces;
                word-break: break-word;
                overflow-wrap: anywhere;
            }

            .theme-balmy code {
                background: rgba(0,0,0,0.05);
                padding: 2px 6px;
                border-radius: 4px;
                white-space: break-spaces;
                word-break: break-word;
                overflow-wrap: anywhere;
            }

            .theme-balmy ul, .theme-balmy ol { margin: 1.2em 0; padding-left: 30px; }
            .theme-balmy li { margin: 0.5em 0; }

            .theme-balmy a {
                color: #d4a574;
                text-decoration: none;
                border-bottom: 1px solid currentColor;
            }

            .theme-balmy img { max-width: 100%; height: auto; border-radius: 8px; margin: 1.5em 0; }
            .theme-balmy .table-wrapper { overflow-x: auto; margin: 1.5em 0; }
            .theme-balmy table { border-collapse: collapse; width: 100%; }

            .theme-balmy th, .theme-balmy td {
                border: 1px solid rgba(0,0,0,0.1);
                padding: 12px;
                text-align: left;
            }

            /* Special Elements */
            .theme-balmy .callout-box {
                background: rgba(0,0,0,0.03);
                border: 1px solid rgba(0,0,0,0.05);
                padding: 20px;
                border-radius: 12px;
                margin: 1.5em 0;
                color: #333; /* Force dark text on light backgrounds */
            }

            /* Box Colors */
            .theme-balmy .callout-box.box-blue { background: #e3f2fd; border-color: #bbdefb; color: #333; }
            .theme-balmy .callout-box.box-green { background: #e8f5e9; border-color: #c8e6c9; color: #333; }
            .theme-balmy .callout-box.box-yellow { background: #fffde7; border-color: #fff9c4; color: #333; }
            .theme-balmy .callout-box.box-red { background: #ffebee; border-color: #ffcdd2; color: #333; }
            .theme-balmy .callout-box.box-purple { background: #f3e5f5; border-color: #e1bee7; color: #333; }

            /* Rect Headers */
            .theme-balmy .rect-header { padding: 15px 20px; border-radius: 6px; margin: 1.5em 0; border-left-width: 5px; border-left-style: solid; font-weight: 600; }
            .theme-balmy .rect-header.color-1 { background: #e3f2fd; border-left-color: #2196f3; color: #0d47a1; }
            .theme-balmy .rect-header.color-2 { background: #e8f5e9; border-left-color: #4caf50; color: #1b5e20; }
            .theme-balmy .rect-header.color-3 { background: #fff3e0; border-left-color: #ff9800; color: #e65100; }
            .theme-balmy .rect-header.color-4 { background: #fce4ec; border-left-color: #e91e63; color: #880e4f; }
            .theme-balmy .rect-header.color-5 { background: #f3e5f5; border-left-color: #9c27b0; color: #4a148c; }
        </style>
    </head>
    <body>
        <article class="theme-balmy">
    """
}
