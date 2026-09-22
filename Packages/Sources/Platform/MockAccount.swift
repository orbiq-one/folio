import Data
import Domain
import Foundation

internal enum MockAccount {
    static let id = "mock:alex@example.com"

    static func populate(repository: SQLiteMailRepository) async throws {
        let account = Account(
            id: id,
            provider: .mock,
            displayName: "Mock Account",
            email: EmailAddress(address: "alex@example.com", name: "Alex Morgan")
        )
        try await repository.upsert(account)

        let mailboxes = [
            Mailbox(id: "inbox", accountId: id, kind: .inbox, name: "Inbox", isSystem: true),
            Mailbox(id: "sent", accountId: id, kind: .sent, name: "Sent", isSystem: true),
            Mailbox(id: "drafts", accountId: id, kind: .drafts, name: "Drafts", isSystem: true),
            Mailbox(id: "archive", accountId: id, kind: .archive, name: "Archive", isSystem: true),
            Mailbox(id: "trash", accountId: id, kind: .trash, name: "Trash", isSystem: true),
            Mailbox(id: "spam", accountId: id, kind: .spam, name: "Spam", isSystem: true),
            Mailbox(id: "starred", accountId: id, kind: .starred, name: "Starred", isSystem: true),
            Mailbox(id: "folder:projects", accountId: id, kind: .folder, name: "Projects"),
            Mailbox(id: "folder:receipts", accountId: id, kind: .folder, name: "Receipts"),
        ]
        for mailbox in mailboxes { try await repository.upsert(mailbox) }

        let messages: [(Message, MessageBody?)] = [
            message("trip-1", "trip", "Weekend in Lisbon", "sam@example.com", "Sam Rivera", ["inbox"], -172_800, "Are you still up for Lisbon next month? I found a great little hotel near Alfama."),
            message("trip-2", "trip", "Re: Weekend in Lisbon", "alex@example.com", "Alex Morgan", ["sent"], -169_200, "Absolutely. I can book the train this week. Thanks!"),
            message("project-1", "project", "Project Atlas kickoff", "jordan@northstar.example", "Jordan Lee", ["inbox", "starred", "folder:projects"], -144_000, "Could we review the first milestone on Thursday? I added the brief to the shared folder."),
            message("project-2", "project", "Re: Project Atlas kickoff", "jordan@northstar.example", "Jordan Lee", ["inbox"], -140_400, "Thursday works for me. I will bring the updated timeline."),
            message("later-1", "later", "Ideas for the team offsite", "priya@example.com", "Priya Shah", ["inbox"], -115_200, "I gathered three venue options for the offsite. Let me know which one you prefer."),
            message("archive-1", "archive", "Reading list for autumn", "sam@example.com", "Sam Rivera", ["archive"], -259_200, "Here are the books I mentioned. The last one is my favorite."),
            message("trash-1", "trash", "Old event reminder", "events@example.com", "Community Events", ["trash"], -345_600, "The event from last spring has been cancelled."),
            message("spam-1", "spam", "You have won a prize", "offers@unknown.example", "Prize Center", ["spam"], -432_000, "Claim your prize today by following this link."),
            (Message(id: "draft-1", accountId: id, threadId: "draft", subject: "Notes for the design review", sender: email("alex@example.com", "Alex Morgan"), to: [email("jordan@northstar.example", "Jordan Lee")], date: date(-7_200), flags: [.draft], mailboxIds: ["drafts"], bodyId: "body-draft-1"), MessageBody(id: "body-draft-1", plainText: "I wanted to share a few notes before our review...")),
            (activity("order-1", "order", "Your parcel is on the way", "shipping@parceltrack.example", "ParcelTrack", ["inbox"], -21_600, "Your order has shipped and will arrive tomorrow. Tracking: PT-48291.")),
            (activity("money-1", "money", "Your monthly invoice is ready", "billing@cloudledger.example", "CloudLedger", ["inbox", "folder:receipts"], -43_200, "Your invoice for €24.00 is ready to view. Payment is due on October 1.", [.read])),
            (activity("security-1", "security", "New sign-in verification code", "security@securebank.example", "SecureBank", ["inbox", "starred"], -64_800, "Your one-time verification code is 184203. It expires in ten minutes.")),
            (activity("notification-1", "notification", "Calendar update: Design review", "notifications@calendar.example", "Calendar", ["inbox"], -86_400, "Jordan Lee changed the time of Design review to Thursday at 10:00.", [.read])),
            (activity("newsletter-1", "newsletter", "Morning Brief: The future of local transit", "digest@morningbrief.example", "Morning Brief", ["inbox"], -108_000, "Five stories worth reading today.", [.read], html: "<html><body><h1>Morning Brief</h1><p>Five stories worth reading today, including the future of local transit.</p></body></html>")),
            message("sent-1", "sent", "Thanks for the introduction", "alex@example.com", "Alex Morgan", ["sent"], -28_800, "Thanks for connecting us. I will follow up next week."),
        ]

        let generated = generated()
        try await repository.upsert((messages + extraMessages + generated.messages).map { message, body in
            var message = message
            let files = attachments[message.id] ?? []
            message.attachmentIds = files.map(\.id)
            return (message, body, files)
        })

        let overrides: [(threadId: String, state: ConversationState)] = [
            ("trip", .waiting), ("later", .later), ("contract", .needsReply), ("dinner", .needsReply), ("hiring", .needsReply),
            ("apartment", .waiting), ("podcast", .waiting), ("taxes", .later), ("recipe", .done), ("bike", .done),
        ]
        for (threadId, state) in overrides {
            try await repository.setOverride(ConversationOverride(accountId: id, threadId: threadId, state: state,
                                                                  until: state == .later ? .distantFuture : nil))
        }
        for override in generated.overrides { try await repository.setOverride(override) }
    }

    static let minute: TimeInterval = 60
    static let hour: TimeInterval = 3_600
    static let day: TimeInterval = 86_400

    private static let attachments: [String: [Attachment]] = [
        "contract-1": [Attachment(id: "att-contract", filename: "Northstar-MSA-v3.pdf", mimeType: "application/pdf", size: 482_113)],
        "apartment-1": [Attachment(id: "att-floorplan", filename: "floorplan.png", mimeType: "image/png", size: 1_204_551)],
        "hiring-1": [Attachment(id: "att-cv", filename: "Mina-Okafor-CV.pdf", mimeType: "application/pdf", size: 210_004)],
    ]

    private static let extraMessages: [(Message, MessageBody?)] = [
        message("contract-1", "contract", "Northstar MSA: final redlines", "legal@northstar.example", "Dana Whitfield", ["inbox"], -56 * minute, "Attached is v3 with our last two redlines on liability. If you can confirm by Friday we can countersign next week."),
        message("cruise-1", "cruise", "Norway fjords next summer?", "omar@example.com", "Omar Haddad", ["inbox"], -1 * day - 6 * hour, "Leila and I are booking a cruise along the Norwegian fjords for July next year. Ten days from Bergen. Would you like to come along? Cabins sell out by November."),
        message("dinner-1", "dinner", "Dinner Saturday?", "mia@example.com", "Mia Chen", ["inbox"], -2 * hour, "We're thinking of trying the new Georgian place on Saturday around 8. Are you in? Bring Sam if he's around."),
        message("hiring-1", "hiring", "Candidate for the design role", "tomas@example.com", "Tomás Herrera", ["inbox"], -3 * hour, "Mina worked with me at Fieldwork for three years. Portfolio and CV attached. Worth a first call?"),
        message("standup-1", "standup", "Standup notes: Sep 22", "jordan@northstar.example", "Jordan Lee", ["inbox"], -4 * hour, "Atlas: API freeze moved to Oct 3. Design: onboarding flows in review. Blockers: none.", read: true),
        message("apartment-1", "apartment", "Viewing at Kastanienallee 12", "k.brandt@example.com", "Katrin Brandt", ["inbox"], -5 * hour, "Thanks for your interest. The floor plan is attached. I can offer a viewing Wednesday at 18:00."),
        message("apartment-2", "apartment", "Re: Viewing at Kastanienallee 12", "alex@example.com", "Alex Morgan", ["sent"], -4 * hour - 30 * minute, "Wednesday at 18:00 works. Is the kitchen included?"),
        message("podcast-1", "podcast", "Guest spot on Build Notes", "hello@buildnotes.example", "Build Notes Podcast", ["inbox"], -13 * hour, "We'd love to have you on to talk about local-first mail. Recording slots are in October.", read: true),
        message("podcast-2", "podcast", "Re: Guest spot on Build Notes", "alex@example.com", "Alex Morgan", ["sent"], -12 * hour, "Happy to join. Any Tuesday in October works for me."),
        message("offsite-2", "offsite", "Offsite agenda draft", "priya@example.com", "Priya Shah", ["inbox"], -14 * hour, "Rough agenda: day one strategy, day two hack day. Comments welcome before Thursday."),
        message("bike-1", "bike", "Your bike is ready for pickup", "shop@velowerk.example", "Velowerk", ["inbox"], -16 * hour, "New chain and brake pads are done. We're open until 19:00.", read: true),
        message("recipe-1", "recipe", "That shakshuka recipe", "mia@example.com", "Mia Chen", ["inbox", "starred"], -17 * hour, "Here it is. The trick is a pinch of cumin and a lot of patience with the onions.", read: true),
        message("taxes-1", "taxes", "Documents for your 2025 return", "office@steuerbuero.example", "Steuerbüro Wagner", ["inbox"], -23 * hour, "Please send the remaining receipts for home office expenses by the end of the month.", read: true),
        message("coffee-1", "coffee", "Coffee next week?", "lena@example.com", "Lena Vogt", ["inbox"], -1 * day - 3 * hour, "I'm in town Tuesday to Thursday. Would love to catch up if you have an hour."),
        message("atlas-3", "atlas-review", "Atlas milestone 1 review notes", "jordan@northstar.example", "Jordan Lee", ["inbox", "folder:projects"], -2 * day, "Thanks for the session. Summary: scope is fine, timeline is tight, we'll revisit staffing next sprint.", read: true),
        message("atlas-4", "atlas-review", "Re: Atlas milestone 1 review notes", "alex@example.com", "Alex Morgan", ["sent", "folder:projects"], -2 * day + 2 * hour, "Agreed. I'll draft the staffing options by Monday."),
        message("atlas-5", "atlas-review", "Re: Atlas milestone 1 review notes", "priya@example.com", "Priya Shah", ["inbox", "folder:projects"], -1 * day - 20 * hour, "Adding: design needs one more week for the onboarding flows.", read: true),
        message("climb-1", "climb", "Bouldering Thursday", "sam@example.com", "Sam Rivera", ["inbox"], -2 * day - 5 * hour, "Usual spot, 19:00? I got a new pair of shoes and need someone to watch me fall.", read: true),
        message("mentor-1", "mentor", "Following up on our chat", "r.okoye@example.com", "Rita Okoye", ["inbox"], -3 * day, "It was great talking about your career plans. Here are the two books I mentioned.", read: true),
        message("wedding-1", "wedding", "Save the date: Mia & Theo", "mia@example.com", "Mia Chen", ["inbox", "starred"], -4 * day, "June 14 next year, near Lake Como. Formal invite follows!", read: true),
        message("neighbor-1", "neighbor", "Parcel for you", "p.kaiser@example.com", "Peter Kaiser", ["inbox"], -5 * day, "I took in a parcel for you this morning. Ring anytime after 17:00.", read: true),
        message("conf-1", "conf", "Speaker confirmation: Swift Berlin", "speakers@swiftberlin.example", "Swift Berlin", ["inbox"], -6 * day, "Your talk 'Local-first mail on macOS' is confirmed for November 12, Hall B.", read: true),
        message("old-1", "old-friend", "Long time no see", "ben@example.com", "Ben Adler", ["archive"], -12 * day, "Saw your name on the Swift Berlin lineup. Congrats! Let's grab a beer when you're here.", read: true),
        message("old-2", "invoice-q", "Question about invoice 2291", "accounts@fieldwork.example", "Fieldwork Accounts", ["archive"], -21 * day, "Could you confirm the PO number for invoice 2291?", read: true),
        activity("gh-1", "gh-1", "[projectmail] PR #142: Dense list layout", "notifications@github.example", "GitHub", ["inbox"], -20 * minute, "leob requested your review on #142."),
        activity("gh-2", "gh-2", "[projectmail] CI failed on main", "notifications@github.example", "GitHub", ["inbox"], -1 * hour - 10 * minute, "Build #812 failed: ThreadListTests.swift:44."),
        activity("gh-3", "gh-3", "[projectmail] Issue #140 closed", "notifications@github.example", "GitHub", ["inbox"], -6 * hour, "Issue 'Sidebar counts drift after sync' was closed.", [.read]),
        activity("order-2", "order-2", "Order confirmed: Kaweco Sport fountain pen", "orders@penshop.example", "Penshop", ["inbox", "folder:receipts"], -9 * hour, "Thanks for your order #58213. Total €29.90.", [.read]),
        activity("money-2", "money-2", "You received €42.50", "no-reply@paylink.example", "Paylink", ["inbox"], -11 * hour, "Sam Rivera sent you €42.50 for 'Lisbon hotel deposit'."),
        activity("security-2", "security-2", "New login from Safari on Mac", "no-reply@accounts.example", "Accounts", ["inbox"], -15 * hour, "We noticed a new sign-in from Berlin, Germany. If this was you, no action needed.", [.read]),
        activity("travel-1", "travel-1", "Your train ticket: Berlin → Hamburg", "tickets@rail.example", "Rail Tickets", ["inbox"], -1 * day - 8 * hour, "ICE 702, Oct 2, 08:34, car 7 seat 45.", [.read]),
        activity("newsletter-2", "newsletter-2", "Swift Weekly #312", "editor@swiftweekly.example", "Swift Weekly", ["inbox"], -2 * day - 2 * hour, "This week: typed throws in practice, SwiftUI list performance, and a GRDB deep dive.", html: "<html><body><h1>Swift Weekly #312</h1><p>Typed throws in practice, SwiftUI list performance, and a GRDB deep dive.</p></body></html>"),
        activity("newsletter-3", "newsletter-3", "The Design Details: Folder icons", "hi@designdetails.example", "Design Details", ["inbox"], -3 * day, "Why the humble folder icon keeps coming back.", [.read], html: "<html><body><h1>Folder icons</h1><p>Why the humble folder icon keeps coming back.</p></body></html>"),
        activity("notification-2", "notification-2", "Reminder: Dentist tomorrow 09:30", "reminders@calendar.example", "Calendar", ["inbox"], -4 * day, "Dr. Hoffmann, Torstraße 88.", [.read]),
    ]

    private static func email(_ address: String, _ name: String? = nil) -> EmailAddress {
        EmailAddress(address: address, name: name)
    }

    private static func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSinceNow: offset)
    }

    private static func message(_ id: String, _ threadId: String, _ subject: String, _ sender: String, _ senderName: String,
                                _ mailboxIds: [String], _ offset: TimeInterval, _ text: String, read: Bool = false) -> (Message, MessageBody?) {
        let bodyId = "body-\(id)"
        let recipients = sender == "alex@example.com"
            ? [email(threadId == "trip" ? "sam@example.com" : "jordan@northstar.example")]
            : [email("alex@example.com", "Alex Morgan")]
        var flags: MessageFlags = sender == "alex@example.com" || read ? [.read] : []
        if mailboxIds.contains("starred") { flags.insert(.starred) }
        let message = Message(id: id, accountId: Self.id, threadId: threadId, subject: subject,
                              sender: email(sender, senderName), to: recipients,
                              date: date(offset), flags: flags, mailboxIds: Set(mailboxIds), bodyId: bodyId)
        return (message, MessageBody(id: bodyId, plainText: text))
    }

    private static func activity(_ id: String, _ threadId: String, _ subject: String, _ sender: String, _ senderName: String,
                                 _ mailboxIds: [String], _ offset: TimeInterval, _ text: String,
                                 _ flags: MessageFlags = [], html: String? = nil) -> (Message, MessageBody?) {
        var messageFlags = flags
        if mailboxIds.contains("starred") { messageFlags.insert(.starred) }
        let bodyId = "body-\(id)"
        let headers = html != nil
            ? ["list-id": sender, "list-unsubscribe": "<mailto:unsubscribe@example.com>"]
            : ["auto-submitted": "auto-generated"]
        let message = Message(id: id, accountId: Self.id, threadId: threadId, subject: subject,
                              sender: email(sender, senderName), to: [email("alex@example.com", "Alex Morgan")],
                              date: date(offset), flags: messageFlags, mailboxIds: Set(mailboxIds), bodyId: bodyId,
                              automationHeaders: headers)
        return (message, MessageBody(id: bodyId, plainText: text, html: html))
    }
}
