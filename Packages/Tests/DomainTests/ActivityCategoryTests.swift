import Domain
import Foundation
import Testing

private struct CategoryFixture: Sendable {
    let sender: String
    let subject: String
    var headers: [String: String] = [:]
    var text: String? = nil
    var html: String? = nil
    let category: ActivityCategory
}

private let categoryFixtures: [CategoryFixture] = [
    .init(sender: "noreply@shop.example", subject: "Your order shipped", category: .orders),
    .init(sender: "tracking@carrier.example", subject: "Update", category: .orders),
    .init(sender: "noreply@delivery.example", subject: "Update", category: .orders),
    .init(sender: "billing@example.com", subject: "Thank you", category: .money),
    .init(sender: "noreply@example.com", subject: "Invoice and receipt", category: .money),
    .init(sender: "noreply@example.com", subject: "Update", text: "Payment received: €24.99", category: .money),
    .init(sender: "noreply@example.com", subject: "$24.99 received", category: .money),
    .init(sender: "noreply@example.com", subject: "24,99 € received", category: .money),
    .init(sender: "editor@example.com", subject: "Weekly edition", headers: ["list-unsubscribe": "<mailto:leave@example.com>", "list-id": "weekly.example.com"], category: .newsletters),
    .init(sender: "digest@example.com", subject: "Today", category: .newsletters),
    .init(sender: "noreply@example.com", subject: "Newsletter: delivery trends and $25 offers", category: .newsletters),
    .init(sender: "noreply@example.com", subject: "VERIFICATION code", category: .security),
    .init(sender: "noreply@example.com", subject: "Your one-time code", category: .security),
    .init(sender: "noreply@example.com", subject: "New sign-in", category: .security),
    .init(sender: "noreply@example.com", subject: "Password changed", category: .security),
    .init(sender: "noreply@example.com", subject: "Security alert", category: .security),
    .init(sender: "noreply@example.com", subject: "Update", html: "<p>Your parcel shipped</p>", category: .orders),
    .init(sender: "noreply@example.com", subject: "Update", text: "Build finished\n\nOn Mon Anna wrote:\n> Your order shipped", category: .notifications),
    .init(sender: "noreply@example.com", subject: "Update", text: "Build finished\n\n-- \nInvoice department", category: .notifications),
    .init(sender: "noreply@example.com", subject: "Border conditions", category: .notifications),
    .init(sender: "noreply@example.com", subject: "Update", text: "One\nTwo\nThree\nFour\nFive\nPayment", category: .notifications),
    .init(sender: "noreply@example.com", subject: "Build passed", headers: ["list-unsubscribe": "<mailto:leave@example.com>"], category: .notifications),
]

@Test(arguments: categoryFixtures)
private func activityClassifierFixtures(_ fixture: CategoryFixture) {
    let message = Message(id: "m", accountId: "a", threadId: "t", subject: fixture.subject,
                          sender: EmailAddress(address: fixture.sender), date: .distantPast,
                          automationHeaders: fixture.headers)
    let body = MessageBody(id: "b", plainText: fixture.text, html: fixture.html)
    #expect(ActivityCategory.classify(message: message, body: body) == fixture.category)
    if fixture.text == nil && fixture.html == nil {
        #expect(ActivityCategory.classify(message: message) == fixture.category)
    }
}

@Test func messageWithoutCategoryDecodesFromExistingPayload() throws {
    let message = Message(id: "m", accountId: "a", threadId: "t", subject: "Hello",
                          sender: EmailAddress(address: "anna@example.com"), date: .distantPast)
    let data = try JSONEncoder().encode(message)
    #expect(try JSONDecoder().decode(Message.self, from: data).activityCategory == nil)
}
