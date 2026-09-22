# UI

How the main window, conversation windows, and compose window behave. For the rules behind these choices, see [decisions](decisions.md) and "UI performance" in the [conventions](conventions.md).

## Main window

The main window has two columns: the sidebar and the message list. Conversations open in their own windows.

### Sidebar

The sidebar is a native `List(selection:)` with `.listStyle(.sidebar)`, so macOS provides selection, focus, keyboard navigation, and Liquid Glass. It has three sections:

1. Attention, Waiting, Later, and Activity
2. Sent and Drafts across all accounts
3. **Accounts** (collapsible): All Inboxes, Flagged, and each account's mailbox tree

Attention is selected by default. Navigation symbols use system blue; selection and standard controls keep the system accent color. The selected label is semibold. There are no custom selection backgrounds.

The column defaults to 240 pt (190 to 360 pt) and remembers its width per window. The list needs at least 480 pt, and the window minimum is the sum of both columns.

### Message list

The list is an AppKit `NSTableView` (`ThreadTableView`) with reusable cells, hosted in SwiftUI. Each single-line row shows:

- Unread dot and sender avatar
- Subject, followed by a one-line preview in secondary color
- State tag (Needs Reply, Later) and message count
- Attachment and flag icons, sender, and compact age (`56m`, `13h`, `2d`)
- A **More Actions** button with the same menu as the context menu

The toolbar centers the mailbox title with a count. **New Message** is in the sidebar toolbar; **Ask Mail**, **Search**, and **Filter Unread** trail.

Interactions:

- Pull down past 70 pt to refresh. The list stays inset with a spinner until sync finishes.
- Swipe left for Move to Trash and Done (Archive in mailboxes). Swipe right for Later (Flag in mailboxes).
- Double-click or press Return to open each selected conversation in its own window.
- Sync updates and mailbox switches don't animate. Search and filter changes animate unless Reduce Motion is on.

List text size runs from 11 to 20 pt in 1 pt steps (default 13). Row height, avatars, tags, and icons scale with it. Change it in **Settings › General › Message List**, or with **View › Make Text Bigger** (`⌘+` or `⌘=`), **Make Text Smaller** (`⌘−`), and **Actual Size** (`⌘0`).

### Activity

Activity is a feed of automated mail, grouped into Orders, Money, Security, Notifications, and Newsletters. Each row is one message; its title is the first line of the cleaned body, so rows show no preview.

- Section headers are plain rows that don't float.
- A sender with more than three unseen items collapses into one row that expands in place.
- A category bar floats at the bottom of the list: All, Orders, Money, Security, Notifications, and Newsletters. Picking a category hides the section headers and filters the rows.
- Opening an item marks only that item as seen.
- Done, Later, and Needs Reply don't apply to Activity. The context menu offers **Treat as Person**, **Reset Sender Rule**, **Move to Trash**, and **Mark as Read** or **Mark as Unread**.

Sender rules (**Treat as Person**, **Treat as Activity**, **Reset Sender Rule**) reclassify all mail from that sender and are also in the **Message** menu.

## Conversation window

Each conversation opens in its own window with **Reply**, **Reply All**, and **Forward** in the toolbar. List actions stay in the list, its menus, the keyboard shortcuts, and the **Message** menu.

- Messages are stacked, oldest first. Older messages are collapsed and the newest is expanded.
- Plain text is cleaned; quoted history, signatures, headers, source, and attachments are behind per-message disclosures. **Settings › General › Reading** controls whether quoted history is hidden.
- HTML renders in `WKWebView` with a strict Content Security Policy. Scripts are off, and remote content stays blocked until you choose **Load remote content**.
- The window shows the conversation state (Needs Reply, Later) and updates it live when you act on the conversation elsewhere. Windows opened from a mailbox or from Ask Mail don't show state.
- Human conversations are marked read 2 seconds after they open.

Newsletters in Activity open in a full-width reader with a compact header, **Load remote content**, and **Unsubscribe**. Unsubscribe opens only a `mailto:` or HTTPS link from the `List-Unsubscribe` header. The reader has no inline reply.

## Compose

- **Inline reply:** a plain-text editor pinned to the bottom of the conversation window. It picks Reply All when there are several other recipients. **Open in Compose Window** moves the draft, with its text, to a compose window.
- **Compose window:** one window per draft, with bold, italic, links, and lists. Quoted history stays out of the editor and is added when the message is sent.
- Drafts save to the server through the outbox, 2 seconds after you stop typing.
- Sending shows an undo banner for 5 seconds before the message goes out.

## Ask Mail

**Ask Mail** in the toolbar replaces the list with a question field. The list stays mounted underneath, hidden. Press Esc, click the button again, or pick a sidebar item to close it; the last question and answer stay for next time.

`MailAssistant` asks Apple Foundation Models for search terms, runs `rankedSearch(anyOf:limit:)` over the full-text index, then asks the model for a short answer, the best matching email, and other relevant emails. If the answer names a different sender than the picked email, that sender's top email wins. The answer card shows:

- The answer
- Whether you replied, computed from the thread rather than by the model
- The best email, with **Open Email** (Return) and, for longer threads, **Open Conversation**
- **Other Emails**, most relevant first

Without Apple Intelligence, Ask Mail extracts keywords from the question and shows the matches without an answer.

## Keyboard shortcuts

Single-key shortcuts work in the message list when you're not typing:

| Key | Action |
|-----|--------|
| `j`, `k` | Next, previous |
| `e` | Done (Archive in mailboxes) |
| `l` | Later, until tomorrow |
| `⇧R` | Needs Reply |
| `s` | Flag or unflag |
| `r` | Reply |
| `c` | New message |
| `⇧U`, `⇧I` | Mark unread, mark read |
| Return | Open |
| `⌫` | Move to Trash |

Every action is also a menu item:

| Shortcut | Action |
|----------|--------|
| `⌃⌘E` | Done |
| `⌃⌘L` | Later, until tomorrow |
| `⌃⌘R` | Needs Reply |
| `⌃⌘A` | Archive |
| `⌘⌫` | Move to Trash |
| `⇧⌘L` | Flag or unflag |
| `⇧⌘U` | Mark read or unread |
| `⌘R`, `⌥⌘R`, `⇧⌘F` | Reply, Reply All, Forward |
| `⇧⌘N` | New message |
| `⇧⌘D`, `⌘S` | Send, Save Draft |
| `⌘O` | Edit draft |
| `⌥⌘↓`, `⌥⌘↑` | Next, previous message |
| `⌘F` | Find |
| `⇧⌘R` | Refresh |
| `⌃⌘P`, `⌃⌥⌘A`, `⌃⌥⌘P` | Treat as Person, Treat as Activity, Reset Sender Rule |
| `⌃⌥⌘S` | Expand or collapse sender |
| `⌃⌥⌘U` | Unsubscribe |
| `⌃⌥⌘I` | Load remote content |

## Settings

- **General:** Dock badge with the Attention count, message list text size, and hiding quoted history.
- **Accounts:** add and remove accounts, and set the sender name for each.
