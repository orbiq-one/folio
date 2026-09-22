import Domain
import Foundation

// Deterministic bulk data so every view has enough rows to scroll and test against.
extension MockAccount {
    private static let me = EmailAddress(address: "alex@example.com", name: "Alex Morgan")

    private static let people: [EmailAddress] = [
        ("Sam Rivera", "sam@example.com"), ("Jordan Lee", "jordan@northstar.example"), ("Priya Shah", "priya@example.com"),
        ("Mia Chen", "mia@example.com"), ("Tomás Herrera", "tomas@example.com"), ("Lena Vogt", "lena@example.com"),
        ("Rita Okoye", "r.okoye@example.com"), ("Ben Adler", "ben@example.com"), ("Katrin Brandt", "k.brandt@example.com"),
        ("Dana Whitfield", "legal@northstar.example"), ("Yuki Tanaka", "yuki@studio-kumo.example"), ("Omar Haddad", "omar@example.com"),
        ("Sofia Marino", "sofia.marino@example.com"), ("Felix Braun", "felix@braun-architekten.example"), ("Grace Park", "grace@example.com"),
        ("Noah Fischer", "noah.fischer@example.com"), ("Amara Diallo", "amara@example.com"), ("Lukas Weber", "lukas@example.com"),
        ("Hannah Schulz", "hannah@example.com"), ("Carlos Mendes", "carlos@mendes.example"),
    ].map { EmailAddress(address: $0.1, name: $0.0) }

    private static let topics: [(subject: String, body: String, reply: String)] = [
        ("Quick question about the roadmap", "Do we still plan to ship search before the holidays, or did that move to Q1?", "Still before the holidays. I'll confirm the date on Monday."),
        ("Photos from the weekend", "Finally sorted the photos from the lake. The sunset ones came out great.", "These are beautiful, thank you!"),
        ("Can you review my draft?", "I put the essay in the shared folder. Mostly looking for feedback on the structure.", "Reading it tonight, notes by tomorrow."),
        ("Lunch on Friday", "Want to grab lunch Friday? There's a new ramen place near the office.", "Yes! 12:30 works."),
        ("Budget for Q4", "Finance wants the Q4 numbers by the 30th. Can you send yours by Wednesday?", "Sending them Tuesday."),
        ("Moving boxes", "Do you still have those moving boxes? We're moving on the 15th.", "About twenty of them, come pick them up."),
        ("Feedback on the prototype", "Played with the prototype for an hour. The onboarding felt great, settings less so.", "Thanks, settings is next on the list."),
        ("Your talk proposal", "We loved the proposal. Could you shorten the abstract to 80 words?", "Done, updated abstract attached."),
        ("Book club: next pick", "Next month's vote is between Piranesi and The Remains of the Day.", "Piranesi, easily."),
        ("Invoice question", "The last invoice lists 12 hours, but my notes say 10. Can you double check?", "You're right, corrected invoice coming."),
        ("Interview schedule", "Can we move the second interview to Thursday afternoon?", "Thursday 15:00 works."),
        ("Garden party", "Garden party at ours on Sunday from 3. Kids welcome, bring a chair.", "We'll be there!"),
        ("Access to the staging server", "I can't log in to staging since the migration. Could you reset my access?", "Reset, check your email."),
        ("Thank you!", "Just wanted to say thanks for the help last week. It made a big difference.", "Anytime, glad it worked out."),
        ("Contract renewal", "Our contract ends in November. Shall we set up a call to talk renewal?", "Yes, how about next Tuesday?"),
        ("Recommendations for Tokyo", "Heading to Tokyo in October. Any restaurants you'd recommend?", "Sending a list tonight."),
        ("Design critique Thursday", "I'll present the new icon set at the critique. 20 minutes enough?", "Take 30, it's a big set."),
        ("Keys for the flat", "I'll leave the spare keys with the neighbour on the second floor.", "Perfect, thanks."),
        ("Paper draft v2", "Revised the methods section based on your comments. Much tighter now.", "Much better. Two small notes inline."),
        ("Hiking this weekend?", "Weather looks good for Saturday. Up for the ridge trail?", "Count me in."),
        ("Help with the spreadsheet", "The pivot table keeps breaking when I add new rows. Any idea why?", "Convert the range to a table first."),
        ("New office hours", "From next week the studio is open 9 to 17, closed Mondays.", "Noted, thanks."),
        ("Birthday plans for Mia", "Secret planning thread: surprise dinner on the 12th?", "I'll book the table."),
        ("API rate limits", "We're hitting the rate limit on the sync endpoint around 9am. Can we raise it?", "Raised to 600/min for now."),
        ("Volunteer shift", "Could you take the Saturday morning shift at the food bank?", "Yes, put me down."),
        ("Architecture review notes", "Notes from today: keep SQLite as source of truth, revisit the sync queue design.", "Agreed on both."),
        ("Referral", "A friend of mine is looking for a Swift developer. Mind if I pass on your name?", "Please do, thanks!"),
        ("Rent increase notice", "Please find the updated rent schedule for next year attached.", "Received, thank you."),
        ("Studio visit", "Would love to show you the new studio. Free any afternoon next week?", "Wednesday afternoon?"),
        ("Conference travel", "Booked flights for the conference. Hotel is still open, want to share?", "Sure, let's share."),
    ]

    private static let activitySources: [(name: String, address: String, subjects: [String], newsletter: Bool)] = [
        ("GitHub", "notifications@github.example", ["[projectmail] PR #%d: Improve sync backoff", "[projectmail] Issue #%d opened: Crash on launch", "[projectmail] CI passed on branch feature/%d"], false),
        ("Linear", "notify@linear.example", ["PM-%d assigned to you", "PM-%d moved to In Review", "Comment on PM-%d"], false),
        ("Penshop", "orders@penshop.example", ["Order #%d confirmed", "Order #%d has shipped"], false),
        ("ParcelTrack", "shipping@parceltrack.example", ["Parcel PT-%d out for delivery", "Parcel PT-%d delivered"], false),
        ("CloudLedger", "billing@cloudledger.example", ["Invoice %d is ready", "Payment received for invoice %d"], false),
        ("Paylink", "no-reply@paylink.example", ["You received €%d.00", "Payment of €%d.00 sent"], false),
        ("SecureBank", "security@securebank.example", ["Verification code %d", "New device sign-in (%d)"], false),
        ("Calendar", "notifications@calendar.example", ["Invitation: Planning sync #%d", "Updated: Design review #%d"], false),
        ("Rail Tickets", "tickets@rail.example", ["Your booking %d", "Delay notice for train %d"], false),
        ("Swift Weekly", "editor@swiftweekly.example", ["Swift Weekly #%d"], true),
        ("Morning Brief", "digest@morningbrief.example", ["Morning Brief No. %d"], true),
        ("Design Details", "hi@designdetails.example", ["Design Details, issue %d"], true),
    ]

    static func generated() -> (messages: [(Message, MessageBody?)], overrides: [ConversationOverride]) {
        var messages: [(Message, MessageBody?)] = []
        var overrides: [ConversationOverride] = []

        for index in 0..<80 {
            let person = people[index % people.count]
            let topic = topics[(index * 7) % topics.count]
            let threadId = "gen-\(index)"
            let newest = -Double(index) * 2.5 * hour - Double(index % 5) * 10 * minute - 15 * minute
            let slot = index % 8
            let mailboxes: Set<String> = slot == 5 || slot == 6 ? ["archive"] : ["inbox"]
            var flags: MessageFlags = []
            if slot >= 3 || index % 3 == 2 { flags.insert(.read) }
            if index % 11 == 0 { flags.insert(.starred) }

            func add(_ suffix: String, from sender: EmailAddress, to recipient: EmailAddress, offset: TimeInterval,
                     subject: String, text: String, flags: MessageFlags, mailboxIds: Set<String>) {
                let id = "\(threadId)-\(suffix)"
                messages.append((Message(id: id, accountId: MockAccount.id, threadId: threadId, subject: subject,
                                         sender: sender, to: [recipient], date: Date(timeIntervalSinceNow: offset),
                                         flags: flags, mailboxIds: mailboxIds, bodyId: "body-\(id)"),
                                 MessageBody(id: "body-\(id)", plainText: text)))
            }

            let isWaiting = slot == 3
            let hasHistory = index % 3 == 0
            if hasHistory {
                add("a", from: person, to: me, offset: newest - 20 * hour, subject: topic.subject, text: topic.body,
                    flags: [.read], mailboxIds: mailboxes)
                add("b", from: me, to: person, offset: newest - 10 * hour, subject: "Re: \(topic.subject)", text: topic.reply,
                    flags: [.read], mailboxIds: ["sent"])
            }
            if isWaiting {
                if !hasHistory {
                    add("a", from: person, to: me, offset: newest - 6 * hour, subject: topic.subject, text: topic.body,
                        flags: [.read], mailboxIds: mailboxes)
                }
                add("c", from: me, to: person, offset: newest, subject: "Re: \(topic.subject)", text: topic.reply,
                    flags: [.read], mailboxIds: ["sent"])
            } else {
                add("c", from: person, to: me, offset: newest, subject: hasHistory ? "Re: \(topic.subject)" : topic.subject,
                    text: hasHistory ? "Following up: \(topic.body)" : topic.body, flags: flags, mailboxIds: mailboxes)
            }

            switch slot {
            case 4:
                overrides.append(ConversationOverride(accountId: id, threadId: threadId, state: .later,
                                                      until: Date(timeIntervalSinceNow: Double(index % 6 + 1) * day)))
            case 7:
                overrides.append(ConversationOverride(accountId: id, threadId: threadId, state: .needsReply))
            default:
                break
            }
        }

        for index in 0..<60 {
            let source = activitySources[index % activitySources.count]
            let number = 100 + index * 37
            let template = source.subjects[(index / activitySources.count) % source.subjects.count]
            let subject = template.replacingOccurrences(of: "%d", with: String(number))
            let messageId = "gen-activity-\(index)"
            let bodyId = "body-\(messageId)"
            let headers = source.newsletter
                ? ["list-id": source.address, "list-unsubscribe": "<mailto:unsubscribe@example.com>"]
                : ["auto-submitted": "auto-generated"]
            let text = "\(subject). This is an automated message from \(source.name)."
            let html = source.newsletter
                ? "<html><body><h1>\(subject)</h1><p>This week's stories, links, and notes from \(source.name).</p></body></html>"
                : nil
            messages.append((Message(id: messageId, accountId: id, threadId: messageId, subject: subject,
                                     sender: EmailAddress(address: source.address, name: source.name), to: [me],
                                     date: Date(timeIntervalSinceNow: -Double(index) * 3.2 * hour - 20 * minute),
                                     flags: index % 4 == 0 ? [] : [.read], mailboxIds: ["inbox"], bodyId: bodyId,
                                     automationHeaders: headers),
                             MessageBody(id: bodyId, plainText: text, html: html)))
        }
        return (messages, overrides)
    }
}
