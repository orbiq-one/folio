import Data
import Domain
import Foundation
import Testing
@testable import Features

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition())
}

@Test @MainActor
func modelsObserveAccountsRowsBodiesAndRemoval() async throws {
    let repository = SQLiteMailRepository(writer: try AppDatabase().writer)
    let sidebar = MailboxSidebarModel(repository: repository)
    let list = ThreadListModel(repository: repository)
    let detail = ThreadDetailModel(repository: repository)
    let sidebarTask = Task { await sidebar.observe() }
    let listTask = Task { await list.observe(.unified(.inbox)) }
    let detailTask = Task { await detail.observe(ThreadSelection(accountId: "a", threadId: "t")) }
    defer { sidebarTask.cancel(); listTask.cancel(); detailTask.cancel() }
    try await waitUntil { !sidebar.isLoading && !list.isLoading && !detail.isLoading }
    #expect(sidebar.accounts.isEmpty)
    #expect(list.rows.isEmpty)
    #expect(detail.thread == nil)
    try await repository.upsert(Account(id: "a", provider: .gmail, displayName: "A", email: EmailAddress(address: "a@example.com")))
    try await repository.upsert(Mailbox(id: "INBOX", accountId: "a", kind: .inbox, name: "Inbox"))
    let first = Message(id: "old", accountId: "a", threadId: "t", subject: "Older", sender: EmailAddress(address: "sender@example.com"),
                        date: Date(timeIntervalSince1970: 100), flags: [.read, .starred], mailboxIds: ["INBOX"])
    try await repository.upsert(first)
    try await waitUntil { detail.expandedMessageIds == ["old"] }
    let latest = Message(id: "new", accountId: "a", threadId: "t", subject: "Newest", sender: EmailAddress(address: "sender@example.com", name: "Sender"),
                         date: Date(timeIntervalSince1970: 200), mailboxIds: ["INBOX"], bodyId: "body", attachmentIds: ["file"])
    try await repository.upsert(latest, body: MessageBody(id: "body", plainText: "First line\nSecond line"),
                                attachments: [Attachment(id: "file", filename: "notes.txt", mimeType: "text/plain", size: 10)])
    try await waitUntil { list.rows.first?.messageCount == 2 && detail.thread?.messages.count == 2 && sidebar.accounts.first?.mailboxes.count == 1 }
    #expect(list.rows.first?.subject == "Newest")
    #expect(list.rows.first?.sender == "Sender")
    #expect(list.rows.first?.snippet == "First line")
    #expect(list.rows.first?.isUnread == true)
    #expect(list.rows.first?.senderAddress == "sender@example.com")
    #expect(list.rows.first?.hasAttachments == true)
    #expect(list.rows.first?.isStarred == true)
    #expect(detail.expandedMessageIds == ["new"])
    #expect(detail.thread?.attachments["file"]?.filename == "notes.txt")
    #expect(detail.thread?.bodies["body"]?.plainText == "First line\nSecond line")
    sidebar.selection = .mailbox(accountId: "a", mailboxId: "INBOX")
    list.selection = ThreadSelection(accountId: "a", threadId: "t")
    try await repository.removeAccount(id: "a")
    try await waitUntil { sidebar.accounts.isEmpty && list.rows.isEmpty && detail.thread == nil }
    #expect(sidebar.selection == .view(.attention))
    #expect(list.selection == nil)
}

@Test @MainActor
func changingSelectionDoesNotLeaveStaleRows() async throws {
    let repository = SQLiteMailRepository(writer: try AppDatabase().writer)
    let list = ThreadListModel(repository: repository)
    let detail = ThreadDetailModel(repository: repository)
    await list.observe(nil)
    detail.loadImages()
    #expect(detail.allowsRemoteImages)
    await detail.observe(nil)
    #expect(!detail.allowsRemoteImages)
    #expect(!detail.hasRemoteImages)
    #expect(list.rows.isEmpty)
    #expect(detail.thread == nil)
    #expect(!list.isLoading && !detail.isLoading)
}

@Test @MainActor
func sidebarOrdersFiltersAndBuildsLabelTrees() async throws {
    let repository = SQLiteMailRepository(writer: try AppDatabase().writer)
    try await repository.upsert(Account(id: "a", provider: .gmail, displayName: "A", email: EmailAddress(address: "a@example.com")))
    let mailboxes = [
        Mailbox(id: "trash", accountId: "a", kind: .trash, name: "Trash"),
        Mailbox(id: "sent", accountId: "a", kind: .sent, name: "Sent"),
        Mailbox(id: "spam", accountId: "a", kind: .spam, name: "Spam"),
        Mailbox(id: "drafts", accountId: "a", kind: .drafts, name: "Drafts"),
        Mailbox(id: "starred", accountId: "a", kind: .starred, name: "Starred"),
        Mailbox(id: "inbox", accountId: "a", kind: .inbox, name: "Inbox"),
        Mailbox(id: "important", accountId: "a", kind: .label, name: "Important", isSystem: true),
        Mailbox(id: "beta", accountId: "a", kind: .label, name: "Beta"),
        Mailbox(id: "alpha", accountId: "a", kind: .label, name: "alpha"),
        Mailbox(id: "work", accountId: "a", kind: .label, name: "Work"),
        Mailbox(id: "hidden", accountId: "a", kind: .label, name: "Hidden", isHidden: true),
        Mailbox(id: "nested", accountId: "a", kind: .label, name: "Work/Team", parentId: "work"),
        Mailbox(id: "hoisted", accountId: "a", kind: .label, name: "Hidden/Visible", parentId: "hidden")
    ]
    for mailbox in mailboxes { try await repository.upsert(mailbox) }
    let model = MailboxSidebarModel(repository: repository)
    let task = Task { await model.observe() }
    defer { task.cancel() }
    try await waitUntil { !model.isLoading }
    #expect(model.mailboxTrees["a"]?.map(\.id) == ["inbox", "starred", "drafts", "sent", "spam", "trash", "important", "alpha", "beta", "hoisted", "work"])
    let work = model.mailboxTrees["a"]?.first { $0.id == "work" }
    #expect(work?.children?.map(\.title) == ["Team"])
    #expect(work?.children?.map(\.id) == ["nested"])
    #expect(model.showsAllAccounts)
    #expect(model.selection == .view(.attention))
    try await repository.upsert(Account(id: "b", provider: .gmail, displayName: "B", email: EmailAddress(address: "b@example.com")))
    try await waitUntil { model.showsAllAccounts }
    model.selection = .unified(.starred)
    try await repository.removeAccount(id: "b")
    try await waitUntil { model.accounts.count == 1 }
    #expect(model.selection == .unified(.starred))
}

@Test @MainActor
func archiveEnqueuesRemovalAndAdvancesSelection() async throws {
    let repository = SQLiteMailRepository(writer: try AppDatabase().writer)
    try await repository.upsert(Account(id: "a", provider: .gmail, displayName: "A", email: EmailAddress(address: "a@example.com")))
    try await repository.upsert(Mailbox(id: "INBOX", accountId: "a", kind: .inbox, name: "Inbox"))
    for (id, date) in [("new", 200.0), ("old", 100.0)] {
        try await repository.upsert(Message(id: id, accountId: "a", threadId: id, subject: id,
                                                   sender: EmailAddress(address: "sender@example.com"),
                                                   date: Date(timeIntervalSince1970: date), mailboxIds: ["INBOX"]))
    }
    let model = ThreadListModel(repository: repository)
    let observation = Task { await model.observe(.unified(.inbox)) }
    defer { observation.cancel() }
    try await waitUntil { model.rows.count == 2 }
    model.selection = model.rows[0].id
    await model.perform(.archive)
    #expect(model.selection == ThreadSelection(accountId: "a", threadId: "old"))
    #expect(try await repository.nextOutboxAction(accountId: "a")?.action == .removeMailbox(messageId: "new", mailboxId: "INBOX"))
}

@Test @MainActor
func archiveMovesToArchiveWhenInboxIsTheOnlyMailbox() async throws {
    let repository = SQLiteMailRepository(writer: try AppDatabase().writer)
    try await repository.upsert(Account(id: "a", provider: .jmap, displayName: "A", email: EmailAddress(address: "a@example.com")))
    try await repository.upsert(Mailbox(id: "inbox", accountId: "a", kind: .inbox, name: "Inbox"))
    try await repository.upsert(Mailbox(id: "archive", accountId: "a", kind: .archive, name: "Archive"))
    try await repository.upsert(Mailbox(id: "work", accountId: "a", kind: .folder, name: "Work"))
    try await repository.upsert(Message(id: "only", accountId: "a", threadId: "only", subject: "only",
                                        sender: EmailAddress(address: "sender@example.com"),
                                        date: Date(timeIntervalSince1970: 200), mailboxIds: ["inbox"]))
    try await repository.upsert(Message(id: "labeled", accountId: "a", threadId: "labeled", subject: "labeled",
                                        sender: EmailAddress(address: "sender@example.com"),
                                        date: Date(timeIntervalSince1970: 100), mailboxIds: ["inbox", "work"]))
    let model = ThreadListModel(repository: repository)
    let observation = Task { await model.observe(.unified(.inbox)) }
    defer { observation.cancel() }
    try await waitUntil { model.rows.count == 2 }
    model.selection = ThreadSelection(accountId: "a", threadId: "only")
    await model.perform(.archive)
    model.selection = ThreadSelection(accountId: "a", threadId: "labeled")
    await model.perform(.archive)
    let first = try #require(try await repository.nextOutboxAction(accountId: "a"))
    #expect(first.action == .move(messageId: "only", fromMailboxId: "inbox", toMailboxId: "archive"))
    try await repository.dequeueOutboxAction(id: first.id, accountId: "a")
    #expect(try await repository.nextOutboxAction(accountId: "a")?.action == .removeMailbox(messageId: "labeled", mailboxId: "inbox"))
}

@Test @MainActor
func detailMarksUnreadMessagesReadAndTogglesStar() async throws {
    let repository = SQLiteMailRepository(writer: try AppDatabase().writer)
    try await repository.upsert(Account(id: "a", provider: .gmail, displayName: "A", email: EmailAddress(address: "a@example.com")))
    let message = Message(id: "m", accountId: "a", threadId: "t", subject: "Subject",
                          sender: EmailAddress(address: "sender@example.com"), date: .now)
    try await repository.upsert(message)
    let model = ThreadDetailModel(repository: repository, markReadDelay: .zero)
    let observation = Task { await model.observe(ThreadSelection(accountId: "a", threadId: "t")) }
    defer { observation.cancel() }
    try await waitUntil { model.thread?.messages.first?.flags.contains(.read) == true }
    await model.star(try #require(model.thread?.messages.first))
    try await waitUntil { model.thread?.messages.first?.flags.contains(.starred) == true }
    await model.star(try #require(model.thread?.messages.first))
    try await waitUntil { model.thread?.messages.first?.flags.contains(.starred) == false }
}

@Test func conversationRenderingCleansBodiesAndExpandsOnlyNewestMessage() {
    let old = Message(id: "old", accountId: "a", threadId: "t", subject: "Older",
                      sender: EmailAddress(address: "old@example.com"), date: Date(timeIntervalSince1970: 100), bodyId: "old-body")
    let newest = Message(id: "new", accountId: "a", threadId: "t", subject: "Newest",
                         sender: EmailAddress(address: "new@example.com"), date: Date(timeIntervalSince1970: 200), bodyId: "new-body")
    let thread = MailThread(id: "t", accountId: "a", messages: [old, newest], bodies: [
        "old-body": MessageBody(id: "old-body", plainText: "First line\nSecond line\n\nOn Monday, Pat wrote:\n> Earlier"),
        "new-body": MessageBody(id: "new-body", plainText: "Newest answer\n\nBest,\nTaylor"),
    ])

    let rendering = ConversationRenderingModel(thread: thread)
    #expect(rendering.expandedMessageIds == ["new"])
    #expect(rendering.message(id: "old")?.displayText == "First line\nSecond line")
    #expect(rendering.message(id: "old")?.firstLine == "First line")
    #expect(rendering.message(id: "old")?.quotedText == "On Monday, Pat wrote:\n> Earlier")
    #expect(rendering.message(id: "new")?.displayText == "Newest answer")
    #expect(rendering.message(id: "new")?.signature == "Best,\nTaylor")
}

@Test func threadDatesRespectTodayYearAndTimeZone() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let locale = Locale(identifier: "en_US_POSIX")
    func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: 30))!
    }
    let now = date(2026, 9, 12, 18)
    let today = date(2026, 9, 12, 10)
    let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
    #expect(ThreadDateFormat.string(for: today, now: now, calendar: calendar, locale: locale) == "Today \(today.formatted(style.hour().minute()))")
    #expect(ThreadDateFormat.string(for: date(2026, 9, 11, 23), now: now, calendar: calendar, locale: locale) == "Yesterday")
    let old = date(2025, 9, 12, 10)
    #expect(ThreadDateFormat.string(for: old, now: now, calendar: calendar, locale: locale) == old.formatted(Date.FormatStyle(date: .numeric, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone)))
    let newYear = date(2027, 1, 1, 0)
    let lastYear = date(2026, 12, 31, 23)
    #expect(ThreadDateFormat.string(for: lastYear, now: newYear, calendar: calendar, locale: locale) == "Yesterday")
}

@Test @MainActor
func avatarAndHTMLPresentationDefaults() {
    #expect(AvatarView.initials(name: "Ada Lovelace", address: "ada@example.com") == "AL")
    #expect(AvatarView.initials(name: "  ", address: "ada@example.com") == "A")
    #expect(AvatarView.colorIndex(address: " ADA@example.com ") == AvatarView.colorIndex(address: "ada@example.com"))
    let hostile = "<img src='https://tracker.example/pixel'><script>alert(1)</script>"
    let document = HTMLMessageView.document(hostile, dark: true)
    #expect(document.contains("default-src 'none'"))
    #expect(document.contains("img-src data:;"))
    #expect(document.contains("html, body { overflow: hidden !important; }"))
    #expect(document.contains("body * { overflow-x: hidden !important; }"))
    #expect(document.contains("blockquote[type=\"cite\" i]"))
    #expect(document.contains("#divRplyFwdMsg ~ *"))
    #expect(document.contains("img[width=\"1\"][height=\"1\"]"))
    let shownQuotes = HTMLMessageView.document("<blockquote type='cite'>Earlier</blockquote>", dark: false, showsQuotedText: true)
    #expect(!shownQuotes.contains(".gmail_quote, #divRplyFwdMsg"))
    #expect(HTMLMessageView.containsQuotedContent("<div class='gmail_quote'>Earlier</div>"))
    #expect(HTMLMessageView.containsQuotedContent("<div id='divRplyFwdMsg'>Earlier</div>"))
    let literalQuote = "<div>My reply<br><br>On 21.9.2026, 22:53, mail@example.com wrote:<br>&gt; Earlier<br>&gt; Still earlier</div>"
    let hiddenLiteralQuote = HTMLMessageView.document(literalQuote, dark: false)
    #expect(hiddenLiteralQuote.contains("My reply"))
    #expect(!hiddenLiteralQuote.contains("Earlier"))
    #expect(HTMLMessageView.containsQuotedContent(literalQuote))
    let shownLiteralQuote = HTMLMessageView.document(literalQuote, dark: false, showsQuotedText: true)
    #expect(shownLiteralQuote.contains("Earlier"))
    let separateBlocks = "<p>My reply</p><p>On 21.9.2026, 22:53, mail@example.com wrote:</p><p>&gt; Earlier</p>"
    #expect(!HTMLMessageView.document(separateBlocks, dark: false).contains("Earlier"))
    let outlook = "<p>My reply</p><div id='divRplyFwdMsg'>-----Original Message-----</div><div>Earlier Outlook message</div>"
    #expect(HTMLMessageView.containsQuotedContent(outlook))
    #expect(HTMLMessageView.document(outlook, dark: false).contains("#divRplyFwdMsg ~ *"))
    let inlineReply = "<div>On 21.9.2026, 22:53, mail@example.com wrote:<br>Actually, here is my new reply.</div>"
    #expect(!HTMLMessageView.containsQuotedContent(inlineReply))
    #expect(!HTMLMessageView.containsQuotedContent("<a title='On 21.9.2026, mail@example.com wrote:'>Link</a>"))
    let allowed = HTMLMessageView.document(hostile, dark: false, allowsRemoteImages: true)
    #expect(allowed.contains("img-src data: https:;"))
    #expect(allowed.contains("script-src 'none'"))
    #expect(!allowed.contains("img-src data: https: http:"))
    #expect(ThreadDetailModel.referencesRemoteImages(hostile))
    #expect(ThreadDetailModel.referencesRemoteImages("<IMG alt='Photo' SRC = \"HTTP://example.com/a.png\">"))
    #expect(ThreadDetailModel.referencesRemoteImages("<img\nsrc=https://example.com/a.png>"))
    #expect(!ThreadDetailModel.referencesRemoteImages("<img src='data:image/png;base64,abc'>"))
    #expect(!ThreadDetailModel.referencesRemoteImages("<a href='https://example.com'>Link</a>"))
    #expect(document.contains("script-src 'none'"))
    #expect(document.contains("form-action 'none'"))
    #expect(document.range(of: "Content-Security-Policy")!.lowerBound < document.range(of: hostile)!.lowerBound)
    #expect(document.contains("color-scheme: dark"))
    #expect(HTMLMessageView.document("<p>Hello</p>", dark: false).contains("color-scheme: light"))
}

private actor FailingAccountService: AccountService {
    func addMockAccount() throws { throw Failure() }
    struct Failure: LocalizedError { var errorDescription: String? { "Missing Google client ID" } }
    func addAccount() throws { throw Failure() }
    func addFastmailAccount(_ credentials: FastmailCredentials) throws { throw Failure() }
    func addIMAPAccount(_ credentials: IMAPCredentials) throws { throw Failure() }
    func removeAccount(id: String) throws { throw Failure() }
    func setSenderName(_ name: String?, accountId: String) throws { throw Failure() }
    func refresh() {}
    func statuses() -> AsyncStream<[String: SyncStatus]> {
        AsyncStream { continuation in continuation.yield(["a": .syncing(SyncProgress(completed: 240, total: 3100))]); continuation.finish() }
    }
}

@Test @MainActor
func accountModelExposesSignInErrorsAndSyncStatus() async {
    let model = AccountModel(service: FailingAccountService())
    #expect(await model.addAccount() == false)
    #expect(model.errorMessage == "Missing Google client ID")
    #expect(!model.isAdding)
    await model.observeStatus()
    #expect(model.isSyncing)
}

@Test
func adaptiveMailColumnLayoutKeepsEachPaneUsable() {
    let sidebar = MailColumnLayout.sidebar

    #expect(sidebar.minimum < sidebar.ideal)
    #expect(sidebar.ideal < sidebar.maximum)
    #expect(sidebar.ideal == 240)
    #expect(MailColumnLayout.windowMinimumWidth >= sidebar.minimum + MailColumnLayout.listMinimum)
    #expect(MailColumnLayout.clamped(100, to: sidebar) == sidebar.minimum)
    #expect(MailColumnLayout.clamped(900, to: sidebar) == sidebar.maximum)
}

@Test
func assistantKeywordsDropQuestionWordsAndDuplicates() {
    #expect(MailAssistant.keywords(in: "Who asked me to go on a cruise next year? Cruise!") == ["cruise"])
    #expect(MailAssistant.keywords(in: "When is my train to Hamburg?") == ["train", "hamburg"])
    #expect(MailAssistant.excerpt("  a\n\n b  ") == "a b")
}

@Test
func assistantReplyStatusAndBestEmail() {
    let me = EmailAddress(address: "alex@example.com")
    let lena = EmailAddress(address: "lena@example.com", name: "Lena Vogt")
    let dana = EmailAddress(address: "dana@example.com", name: "Dana Whitfield")
    func message(_ id: String, from sender: EmailAddress, at time: Double, flags: MessageFlags = []) -> Message {
        Message(id: id, accountId: "a", threadId: "t", subject: "Coffee", sender: sender, date: Date(timeIntervalSince1970: time), flags: flags)
    }
    let ask = message("ask", from: lena, at: 100)
    let draft = message("draft", from: me, at: 200, flags: [.draft])
    let reply = message("reply", from: me, at: 300)
    #expect(ReplyStatus.of(ask, in: MailThread(id: "t", accountId: "a", messages: [ask, draft]), accountEmail: me.address) == .notReplied)
    #expect(ReplyStatus.of(ask, in: MailThread(id: "t", accountId: "a", messages: [ask, draft, reply]), accountEmail: me.address) == .replied(reply.date))
    #expect(ReplyStatus.of(reply, in: MailThread(id: "t", accountId: "a", messages: [ask, reply]), accountEmail: me.address) == nil)

    let lunch = AssistantResult(message: message("lunch", from: dana, at: 400), excerpt: "")
    let coffee = AssistantResult(message: ask, excerpt: "")
    let results = [lunch, coffee]
    #expect(MailAssistant.bestResult(numbered: lunch, answer: "Lena Vogt asked to grab a coffee.", results: results) == coffee)
    #expect(MailAssistant.bestResult(numbered: coffee, answer: "Lena Vogt asked to grab a coffee.", results: results) == coffee)
    #expect(MailAssistant.bestResult(numbered: nil, answer: "Nobody asked.", results: results) == nil)
}

@Test
func listTextSizeScalesFromCompactAndClamps() {
    let standard = ListTextSize.Metrics(textSize: ListTextSize.standard)
    #expect(standard.rowHeight == 34 && standard.avatarSize == 20 && standard.textSize == 13)
    #expect(ListTextSize.Metrics(textSize: 99) == ListTextSize.Metrics(textSize: ListTextSize.range.upperBound))
    #expect(ListTextSize.Metrics(textSize: 20).rowHeight > standard.rowHeight)
    #expect(ListTextSize.clamped(12.6) == 13)
}
