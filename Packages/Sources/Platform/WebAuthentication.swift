import AppKit
import AuthenticationServices
import Foundation

// AuthenticationServices calls both the anchor provider and the completion handler off the main
// thread, so those entry points must stay nonisolated; everything else hops to the main actor.
final class WebAuthentication: NSObject, ASWebAuthenticationPresentationContextProviding, @unchecked Sendable {
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var canceled = false
    private nonisolated(unsafe) var anchor: NSWindow?

    static func authenticate(url: URL, scheme: String) async throws -> URL {
        let browser = WebAuthentication()
        let completion = completionHandler(for: browser)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task {
                    await MainActor.run {
                        browser.continuation = continuation
                        if browser.canceled { browser.finish(.failure(CancellationError())); return }
                        browser.session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme, completionHandler: completion)
                        browser.anchor = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first
                        browser.session?.presentationContextProvider = browser
                        if browser.session?.start() != true { browser.finish(.failure(OAuthError.denied)) }
                    }
                }
            }
        } onCancel: {
            Task {
                await MainActor.run {
                    browser.canceled = true
                    browser.session?.cancel()
                    browser.finish(.failure(CancellationError()))
                }
            }
        }
    }

    nonisolated static func completionHandler(for browser: WebAuthentication) -> @Sendable (URL?, (any Error)?) -> Void {
        { url, error in
            Task {
                await MainActor.run {
                    if let url { browser.finish(.success(url)) }
                    else { browser.finish(.failure(error ?? OAuthError.denied)) }
                }
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor ?? ASPresentationAnchor()
    }

    @MainActor
    static func awaitCompletion(_ browser: WebAuthentication) async throws -> URL {
        try await withCheckedThrowingContinuation { browser.continuation = $0 }
    }

    @MainActor
    private func finish(_ result: Result<URL, Error>) {
        let continuation = continuation
        self.continuation = nil
        session = nil
        continuation?.resume(with: result)
    }
}
