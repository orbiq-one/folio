import Domain
import GRDB

public struct AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(path: String? = nil) throws {
        let database: any DatabaseWriter
        if let path, path != ":memory:" {
            database = try DatabasePool(path: path)
        } else {
            database = try DatabaseQueue()
        }
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE account (
                    id TEXT PRIMARY KEY NOT NULL,
                    provider TEXT NOT NULL,
                    displayName TEXT NOT NULL,
                    email TEXT NOT NULL,
                    capabilities INTEGER NOT NULL
                );
                CREATE TABLE mailbox (
                    accountId TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
                    id TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    name TEXT NOT NULL,
                    parentId TEXT,
                    PRIMARY KEY (accountId, id),
                    FOREIGN KEY (accountId, parentId) REFERENCES mailbox(accountId, id)
                        DEFERRABLE INITIALLY DEFERRED
                );
                CREATE INDEX mailbox_kind ON mailbox(kind, accountId);
                CREATE TABLE message (
                    rowid INTEGER PRIMARY KEY,
                    accountId TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
                    id TEXT NOT NULL,
                    threadId TEXT NOT NULL,
                    subject TEXT NOT NULL,
                    sender TEXT NOT NULL,
                    recipients TEXT NOT NULL,
                    cc TEXT NOT NULL,
                    bcc TEXT NOT NULL,
                    replyTo TEXT NOT NULL,
                    date DOUBLE NOT NULL,
                    internetMessageId TEXT,
                    inReplyTo TEXT,
                    referenceIds TEXT NOT NULL,
                    flags INTEGER NOT NULL,
                    bodyId TEXT,
                    UNIQUE (accountId, id),
                    UNIQUE (accountId, bodyId)
                );
                CREATE INDEX message_thread ON message(accountId, threadId, date);
                CREATE INDEX message_date ON message(date DESC);
                CREATE TABLE message_body (
                    accountId TEXT NOT NULL,
                    id TEXT NOT NULL,
                    plainText TEXT,
                    html TEXT,
                    PRIMARY KEY (accountId, id),
                    FOREIGN KEY (accountId, id) REFERENCES message(accountId, bodyId) ON DELETE CASCADE
                );
                CREATE TABLE message_mailbox (
                    accountId TEXT NOT NULL,
                    messageId TEXT NOT NULL,
                    mailboxId TEXT NOT NULL,
                    PRIMARY KEY (accountId, messageId, mailboxId),
                    FOREIGN KEY (accountId, messageId) REFERENCES message(accountId, id) ON DELETE CASCADE,
                    FOREIGN KEY (accountId, mailboxId) REFERENCES mailbox(accountId, id) ON DELETE CASCADE
                );
                CREATE INDEX message_mailbox_lookup ON message_mailbox(accountId, mailboxId, messageId);
                CREATE TABLE attachment (
                    accountId TEXT NOT NULL,
                    id TEXT NOT NULL,
                    messageId TEXT NOT NULL,
                    position INTEGER NOT NULL,
                    filename TEXT NOT NULL,
                    mimeType TEXT NOT NULL,
                    size INTEGER NOT NULL CHECK (size >= 0),
                    contentHash TEXT,
                    PRIMARY KEY (accountId, id),
                    FOREIGN KEY (accountId, messageId) REFERENCES message(accountId, id) ON DELETE CASCADE
                );
                CREATE INDEX attachment_message ON attachment(accountId, messageId, position);
                CREATE TABLE outbox (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    accountId TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
                    action TEXT NOT NULL,
                    notBefore DOUBLE NOT NULL
                );
                CREATE INDEX outbox_account ON outbox(accountId, id);
                CREATE TABLE sync_state (
                    accountId TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
                    scope TEXT NOT NULL,
                    cursor TEXT NOT NULL,
                    PRIMARY KEY (accountId, scope)
                );
                CREATE VIRTUAL TABLE message_fts USING fts5(subject, sender, plainText);
                CREATE TRIGGER message_insert AFTER INSERT ON message BEGIN
                    INSERT INTO message_fts(rowid, subject, sender, plainText)
                    VALUES (new.rowid, new.subject,
                        COALESCE(json_extract(new.sender, '$.name'), '') || ' ' || json_extract(new.sender, '$.address'), '');
                END;
                CREATE TRIGGER message_update AFTER UPDATE ON message BEGIN
                    UPDATE message_fts SET subject = new.subject,
                        sender = COALESCE(json_extract(new.sender, '$.name'), '') || ' ' || json_extract(new.sender, '$.address'),
                        plainText = COALESCE((SELECT plainText FROM message_body
                            WHERE accountId = new.accountId AND id = new.bodyId), '')
                    WHERE rowid = new.rowid;
                END;
                CREATE TRIGGER message_delete AFTER DELETE ON message BEGIN
                    DELETE FROM message_fts WHERE rowid = old.rowid;
                END;
                CREATE TRIGGER body_insert AFTER INSERT ON message_body BEGIN
                    UPDATE message_fts SET plainText = COALESCE(new.plainText, '')
                    WHERE rowid = (SELECT rowid FROM message WHERE accountId = new.accountId AND bodyId = new.id);
                END;
                CREATE TRIGGER body_update AFTER UPDATE ON message_body BEGIN
                    UPDATE message_fts SET plainText = COALESCE(new.plainText, '')
                    WHERE rowid = (SELECT rowid FROM message WHERE accountId = new.accountId AND bodyId = new.id);
                END;
                CREATE TRIGGER body_delete AFTER DELETE ON message_body BEGIN
                    UPDATE message_fts SET plainText = ''
                    WHERE rowid = (SELECT rowid FROM message WHERE accountId = old.accountId AND bodyId = old.id);
                END;
                """)
        }
        migrator.registerMigration("v2") { db in
            try db.execute(sql: """
                ALTER TABLE mailbox ADD COLUMN isHidden BOOLEAN NOT NULL DEFAULT 0;
                ALTER TABLE mailbox ADD COLUMN isSystem BOOLEAN NOT NULL DEFAULT 0;
                """)
        }
        migrator.registerMigration("v3") { db in
            try db.execute(sql: """
                ALTER TABLE message ADD COLUMN trafficKind TEXT NOT NULL DEFAULT 'human';
                ALTER TABLE message ADD COLUMN automationHeaders TEXT NOT NULL DEFAULT '{}';
                ALTER TABLE message_body ADD COLUMN displayText TEXT;
                CREATE TABLE conversation_override (
                    accountId TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
                    threadId TEXT NOT NULL,
                    state TEXT NOT NULL,
                    until DOUBLE,
                    setAt DOUBLE NOT NULL,
                    PRIMARY KEY (accountId, threadId)
                );
                CREATE TABLE sender_rule (
                    accountId TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
                    address TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    setAt DOUBLE NOT NULL,
                    PRIMARY KEY (accountId, address)
                );
                DROP TRIGGER message_update;
                DROP TRIGGER body_insert;
                DROP TRIGGER body_update;
                CREATE TRIGGER message_update AFTER UPDATE ON message BEGIN
                    UPDATE message_fts SET subject = new.subject,
                        sender = COALESCE(json_extract(new.sender, '$.name'), '') || ' ' || json_extract(new.sender, '$.address'),
                        plainText = COALESCE((SELECT COALESCE(displayText, plainText) FROM message_body
                            WHERE accountId = new.accountId AND id = new.bodyId), '')
                    WHERE rowid = new.rowid;
                END;
                CREATE TRIGGER body_insert AFTER INSERT ON message_body BEGIN
                    UPDATE message_fts SET plainText = COALESCE(new.displayText, new.plainText, '')
                    WHERE rowid = (SELECT rowid FROM message WHERE accountId = new.accountId AND bodyId = new.id);
                END;
                CREATE TRIGGER body_update AFTER UPDATE ON message_body BEGIN
                    UPDATE message_fts SET plainText = COALESCE(new.displayText, new.plainText, '')
                    WHERE rowid = (SELECT rowid FROM message WHERE accountId = new.accountId AND bodyId = new.id);
                END;
                """)
            try SQLiteMailRepository.rebuildDerivedData(db, activityCategories: false)
        }
        migrator.registerMigration("v4") { db in
            try db.execute(sql: "ALTER TABLE message ADD COLUMN activityCategory TEXT")
            try SQLiteMailRepository.rebuildDerivedData(db)
        }
        migrator.registerMigration("v5") { db in
            try db.execute(sql: "ALTER TABLE account ADD COLUMN senderNameInitialized BOOLEAN NOT NULL DEFAULT 0")
        }
        try migrator.migrate(database)
        writer = database
    }
}
