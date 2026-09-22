import Domain
import Foundation
import Testing

private let me = "me@example.com"

private func message(_ id: String, from: String, date: Double, mailboxIds: Set<String> = ["INBOX"],
                     headers: [String: String] = [:], flags: MessageFlags = []) -> Message {
    Message(id: id, accountId: "a", threadId: "t", subject: "Subject", sender: EmailAddress(address: from),
            to: [EmailAddress(address: from == me ? "them@example.com" : me)], date: Date(timeIntervalSince1970: date),
            flags: flags, mailboxIds: mailboxIds, automationHeaders: headers)
}

private let facts = ConversationFacts(accountEmail: me, inboxMailboxIds: ["INBOX"], hiddenMailboxIds: ["TRASH", "SPAM"])

private func infer(_ messages: [Message], override: ConversationOverride? = nil, kinds: [String: TrafficKind] = [:],
                   now: Double = 1_000) -> ConversationState? {
    StateInference.infer(messages: messages, kinds: kinds, facts: facts, override: override, now: Date(timeIntervalSince1970: now)).state
}

@Test func headersAndSenderPatternsMarkActivity() {
    func kind(_ m: Message, known: Bool = false, rule: TrafficKind? = nil) -> TrafficKind {
        TrafficClassifier.classify(m, accountEmail: me, isKnownContact: known, rule: rule)
    }
    #expect(kind(message("1", from: "anna@example.com", date: 1)) == .human)
    #expect(kind(message("2", from: "anna@example.com", date: 1, headers: ["list-unsubscribe": "<mailto:x>"])) == .activity)
    #expect(kind(message("3", from: "anna@example.com", date: 1, headers: ["precedence": "bulk"])) == .activity)
    #expect(kind(message("4", from: "anna@example.com", date: 1, headers: ["auto-submitted": "auto-generated"])) == .activity)
    #expect(kind(message("5", from: "anna@example.com", date: 1, headers: ["auto-submitted": "no"])) == .human)
    #expect(kind(message("6", from: "noreply@shop.example", date: 1)) == .activity)
    #expect(kind(message("7", from: "no-reply-billing@shop.example", date: 1)) == .activity)
    #expect(kind(message("8", from: "support@shop.example", date: 1)) == .human)
    // A person I have written to stays human even through a list.
    #expect(kind(message("9", from: "anna@example.com", date: 1, headers: ["list-id": "team.example"]), known: true) == .human)
    // The user's rule wins over everything.
    #expect(kind(message("10", from: "noreply@shop.example", date: 1), rule: .human) == .human)
    #expect(kind(message("11", from: "anna@example.com", date: 1), known: true, rule: .activity) == .activity)
    #expect(kind(message("12", from: me, date: 1, headers: ["list-id": "x"])) == .human)
    #expect(TrafficClassifier.automationHeaders([(name: "List-ID", value: "x"), (name: "Subject", value: "y")]) == ["list-id": "x"])
}

@Test func stateIsInferredFromInboxMembershipAndAuthorship() {
    let inbound = message("1", from: "anna@example.com", date: 100)
    let mine = message("2", from: me, date: 200)
    #expect(infer([inbound]) == .attention)
    #expect(infer([inbound, mine]) == .waiting)
    #expect(infer([mine, inbound, message("3", from: "anna@example.com", date: 300)]) == .attention)
    #expect(infer([message("1", from: "anna@example.com", date: 100, mailboxIds: ["ARCHIVE"])]) == .done)
    #expect(infer([message("1", from: "anna@example.com", date: 100, mailboxIds: ["TRASH"])]) == nil)
    #expect(infer([message("1", from: "anna@example.com", date: 100, mailboxIds: [])]) == .done, "Gmail archive leaves no labels")
    #expect(infer([inbound, message("d", from: me, date: 500, mailboxIds: ["DRAFTS"], flags: .draft)]) == .attention)
}

@Test func activityConversationsHaveNoWorkflowState() {
    let inbound = message("1", from: "noreply@shop.example", date: 100)
    let result = StateInference.infer(messages: [inbound], kinds: ["1": .activity], facts: facts, override: nil)
    #expect(result.kind == .activity)
    #expect(result.state == nil)
    #expect(StateInference.matches(nil, kind: .activity, view: .activity))
    #expect(!StateInference.matches(.attention, kind: .human, view: .activity))
    #expect(StateInference.matches(.needsReply, kind: .human, view: .attention))
}

@Test func overridesApplyUntilServerFactsMoveOn() {
    let inbound = message("1", from: "anna@example.com", date: 100)
    let mine = message("2", from: me, date: 200)
    func override(_ state: ConversationState, until: Double? = nil, setAt: Double = 150) -> ConversationOverride {
        ConversationOverride(accountId: "a", threadId: "t", state: state, until: until.map(Date.init(timeIntervalSince1970:)),
                             setAt: Date(timeIntervalSince1970: setAt))
    }
    #expect(infer([inbound], override: override(.later, until: 2_000)) == .later)
    #expect(infer([inbound], override: override(.later, until: 500)) == .attention, "expired later falls back")
    #expect(infer([inbound, message("3", from: "anna@example.com", date: 300)], override: override(.later, until: 2_000)) == .attention,
            "new inbound breaks later")
    #expect(infer([inbound], override: override(.needsReply)) == .needsReply)
    #expect(infer([inbound, message("3", from: "anna@example.com", date: 300)], override: override(.needsReply)) == .needsReply)
    #expect(infer([inbound, mine], override: override(.needsReply)) == .waiting, "my reply clears needsReply")
    #expect(infer([inbound, mine], override: override(.attention, setAt: 250)) == .attention, "reopen")
    #expect(infer([inbound, mine, message("3", from: "anna@example.com", date: 300)], override: override(.attention, setAt: 250)) == .attention)
    #expect(infer([inbound], override: override(.done)) == .done)
    #expect(infer([inbound, message("3", from: "anna@example.com", date: 300)], override: override(.done)) == .attention)
}

@Test func bodyCleanerStripsQuotesSignaturesAndFooters() {
    let gmail = """
    Sounds good, see you Thursday.

    On Mon, 1 Sep 2025 at 10:00, Anna <anna@example.com> wrote:
    > Can we meet Thursday?
    > Anna
    """
    #expect(BodyCleaner.clean(gmail).displayText == "Sounds good, see you Thursday.")
    #expect(BodyCleaner.clean(gmail).quotedText?.contains("Can we meet Thursday?") == true)

    let outlook = "Yes.\n\nFrom: Anna <anna@example.com>\nSent: Monday\nTo: Me\nSubject: Re: Meeting\n\nCan we meet?"
    #expect(BodyCleaner.clean(outlook).displayText == "Yes.")

    let signed = "Thanks for the update, I will review it tomorrow.\n\n-- \nLeon Breuer\nCTO, Example GmbH\n+49 30 1234567"
    let result = BodyCleaner.clean(signed)
    #expect(result.displayText == "Thanks for the update, I will review it tomorrow.")
    #expect(result.signature?.contains("Leon Breuer") == true)

    let heuristicSignature = "Sure, works for me.\n\nAnna Müller\nHead of Sales\nwww.example.com"
    #expect(BodyCleaner.clean(heuristicSignature).displayText == "Sure, works for me.")

    let closing = "Let me know what you think.\n\nBest regards,\nAnna"
    #expect(BodyCleaner.clean(closing).displayText == "Let me know what you think.")

    let footer = "Your order has shipped.\n\nThis email was sent to me@example.com. Unsubscribe here or manage your preferences."
    #expect(BodyCleaner.clean(footer).displayText == "Your order has shipped.")

    let onlyQuote = "> original text\n> more"
    #expect(BodyCleaner.clean(onlyQuote).displayText == "original text\nmore")

    let interleaved = "> question one?\nAnswer one.\n> question two?\nAnswer two."
    #expect(BodyCleaner.clean(interleaved).displayText == interleaved)

    #expect(BodyCleaner.clean("").displayText == "")
    #expect(BodyCleaner.clean("Sent from my iPhone").displayText == "Sent from my iPhone", "nothing else to show, keep the text")
}

@Test func htmlBodiesBecomeReadableText() {
    let html = """
    <html><head><style>p{color:red}</style></head><body>
    <p>Hello&nbsp;there,</p><p>Your invoice is attached.</p>
    <img src="https://t.example/pixel.gif" width="1" height="1">
    <div style="display:none">preheader junk</div>
    <p>Regards,<br>Shop</p></body></html>
    """
    let cleaned = BodyCleaner.clean(plainText: nil, html: html)
    #expect(cleaned.displayText == "Hello there,\n\nYour invoice is attached.")
    #expect(HTMLText.plainText(from: "&lt;tag&gt; &amp; &#8217;s &#x41;") == "<tag> & ’s A")
    #expect(BodyCleaner.clean(plainText: "  ", html: "<p>Fallback</p>").displayText == "Fallback")
    #expect(BodyCleaner.clean(plainText: "Plain wins", html: "<p>HTML</p>").displayText == "Plain wins")
}
