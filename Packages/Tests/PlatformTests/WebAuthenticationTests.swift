import Foundation
import Testing
@testable import Platform

// Regression: AuthenticationServices invokes the completion handler on an XPC queue, never the main thread.
@MainActor
@Test func completionHandlerToleratesBackgroundQueue() async throws {
    let browser = WebAuthentication()
    let handler = WebAuthentication.completionHandler(for: browser)
    let expected = URL(string: "com.example:/oauth2redirect?code=abc&state=xyz")!
    let result = Task { try await WebAuthentication.awaitCompletion(browser) }
    try await Task.sleep(for: .milliseconds(50))
    DispatchQueue.global(qos: .userInitiated).async { handler(expected, nil) }
    #expect(try await result.value == expected)
}

@MainActor
@Test func completionHandlerReportsErrorFromBackgroundQueue() async throws {
    let browser = WebAuthentication()
    let handler = WebAuthentication.completionHandler(for: browser)
    let result = Task { try await WebAuthentication.awaitCompletion(browser) }
    try await Task.sleep(for: .milliseconds(50))
    DispatchQueue.global().async { handler(nil, nil) }
    await #expect(throws: OAuthError.self) { try await result.value }
}
