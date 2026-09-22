import AppKit
import SwiftUI
import WebKit

@MainActor
struct HTMLMessageView: NSViewRepresentable {
    let html: String
    var allowsRemoteImages = false
    var showsQuotedText = false
    @Binding var height: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    static func document(_ html: String, dark: Bool, allowsRemoteImages: Bool = false, showsQuotedText: Bool = false) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:\(allowsRemoteImages ? " https:" : ""); style-src 'unsafe-inline'; script-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <meta name="color-scheme" content="\(dark ? "dark" : "light")">
        <style>
        :root { color-scheme: \(dark ? "dark" : "light"); }
        html, body { margin: 0; padding: 0; background: transparent !important; color: CanvasText; font: -apple-system-body; overflow-wrap: anywhere; }
        html, body { overflow: hidden !important; }
        body * { overflow-x: hidden !important; }
        body { font-family: -apple-system, sans-serif; font-size: 13px; line-height: 1.5; }
        \(dark ? "body, body * { color: CanvasText !important; background-color: transparent !important; }" : "")
        img { max-width: 100%; height: auto; } table { max-width: 100%; } pre { white-space: pre-wrap; }
        img[width="1"][height="1"], img[width="0"], img[height="0"], [hidden],
        [style*="display:none" i], [style*="display: none" i] { display: none !important; }
        \(showsQuotedText ? "" : "blockquote[type=\"cite\" i], .gmail_quote, #divRplyFwdMsg, #divRplyFwdMsg ~ *, #appendonsend, #appendonsend ~ * { display: none !important; }")
        body a, body a * { color: LinkText !important; }
        blockquote { margin-left: 12px; padding-left: 12px; border-left: 2px solid GrayText; }
        summary { color: LinkText !important; cursor: pointer; }
        :focus-visible { outline: 2px solid Highlight; outline-offset: 2px; }
        ::selection { color: HighlightText; background: Highlight; }
        </style></head><body>\(showsQuotedText ? html : htmlWithHiddenUnmarkedQuote(in: html))</body></html>
        """
    }

    @MainActor
    private final class ContentSizedWebView: WKWebView {
        // The conversation owns scrolling because this view is sized to its content.
        override func scrollWheel(with event: NSEvent) {
            nextResponder?.scrollWheel(with: event)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let controller = configuration.userContentController
        controller.add(context.coordinator, contentWorld: .defaultClient, name: "messageHeight")
        controller.addUserScript(WKUserScript(source: """
            const report = () => window.webkit.messageHandlers.messageHeight.postMessage(Math.max(document.body.scrollHeight, document.body.getBoundingClientRect().height));
            new ResizeObserver(report).observe(document.body);
            window.addEventListener('load', report); report();
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        let view = ContentSizedWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.height = $height
        let document = Self.document(html, dark: colorScheme == .dark, allowsRemoteImages: allowsRemoteImages,
                                     showsQuotedText: showsQuotedText)
        guard context.coordinator.document != document else { return }
        context.coordinator.document = document
        view.loadHTMLString(document, baseURL: nil)
    }

    static func containsQuotedContent(_ html: String) -> Bool {
        html.range(of: #"(?is)<blockquote\b[^>]*\btype\s*=\s*[\"']?cite\b|class\s*=\s*[\"'][^\"']*\bgmail_quote\b|id\s*=\s*[\"'](?:divRplyFwdMsg|appendonsend)\b"#,
                   options: .regularExpression) != nil || htmlWithHiddenUnmarkedQuote(in: html) != html
    }

    private static func htmlWithHiddenUnmarkedQuote(in html: String) -> String {
        guard let header = html.range(of: #"(?is)\bOn\b(?:(?!<script\b).){0,240}?\bwrote\s*:\s*"#, options: .regularExpression) else { return html }
        let beforeHeader = String(html[..<header.lowerBound])
        guard beforeHeader.split(separator: ">", omittingEmptySubsequences: false).last?.allSatisfy({ $0.isWhitespace }) == true else { return html }
        let tail = String(html[header.lowerBound...])
        let text = tail
            .replacingOccurrences(of: #"(?is)<(br|/?div|/?p|/?li)\b[^>]*>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<[^>]*>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"&(?:gt|#0*62);"#, with: ">", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "&nbsp;", with: " ", options: .caseInsensitive)
        let lines = text.components(separatedBy: .newlines).dropFirst()
        guard !lines.isEmpty, lines.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              lines.allSatisfy({ line in
                  let line = line.trimmingCharacters(in: .whitespaces)
                  return line.isEmpty || line.hasPrefix(">")
              }) else { return html }

        return beforeHeader
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "messageHeight", contentWorld: .defaultClient)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var height: Binding<CGFloat>
        var document: String?

        init(height: Binding<CGFloat>) { self.height = height }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let value = message.body as? Double, value.isFinite, value >= 0 else { return }
            let measured = min(max(CGFloat(value), 40), 20_000)
            if abs(height.wrappedValue - measured) > 1 { height.wrappedValue = measured }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            let isInitialDocument = navigationAction.navigationType == .other
                && navigationAction.request.url?.absoluteString == "about:blank"
                && navigationAction.targetFrame?.isMainFrame == true
            decisionHandler(isInitialDocument ? .allow : .cancel)
        }
    }
}
