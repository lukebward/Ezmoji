# Ezmoji design

One-sentence spec: a menu-bar-only macOS app that watches keystrokes system-wide, detects
`:query` sequences, shows a non-focus-stealing picker, and replaces the typed shortcode with the
chosen emoji.

## Approach chosen

**Global CGEventTap + synthetic keystroke replacement** (the Rocket approach).

Alternatives considered and rejected:
- *Input Method Kit (custom input source)* — the "correct" way, but users must switch keyboard
  input sources, and IMK is far more code. Not simple.
- *macOS text replacements* — no fuzzy picker, each emoji needs a manual entry. Doesn't match the
  Slack UX at all.

## Components (single `Sources/main.swift`, ~550 lines)

| Component | Responsibility |
|---|---|
| `EmojiIndex` | Load `emoji.json` (gemoji-derived), prefix-then-substring match, exact lookup. Pure logic, covered by `--selftest`. |
| `EmojiTapController` | The state machine: `idle` → `active(query)`. Owns the CGEventTap, decides consume vs pass-through per keystroke. |
| `PickerPanel` | Borderless, non-activating `NSPanel` (never takes key focus — the target app keeps typing focus the whole time). Manual frame layout, ≤8 rows. |
| `CaretLocator` | Caret screen position via the AX API (`AXSelectedTextRange` → `AXBoundsForRange`), falling back to the mouse location. Anchored once per session so the panel doesn't jitter. |
| `ExclusionList` | UserDefaults-backed bundle-ID set where Ezmoji stays dormant. Seeded with ~22 apps that have native `:emoji:` autocomplete (Slack, Discord ×3, Telegram ×2, WhatsApp, Signal, Teams ×2, Element, Mattermost, Rocket.Chat, Zulip, Beeper, Notion, Figma, Linear, ClickUp, Asana, GitHub Desktop, Claude). Zoom deliberately omitted — its shortcodes have no keyboard autocomplete. Managed from the status menu. |
| `Typist` | Posts synthetic backspaces + a unicode-string keyboard event. Marks its events with a magic `eventSourceUserData` so the tap ignores its own output. |
| `AppDelegate` | Status item, permission prompt + poll-until-granted, Pause, Launch at Login (`SMAppService`), Quit. |

## Key decisions

- **Trigger rule**: `:` arms the session only when the previously typed character was not a
  letter/digit (kills `std::vector`, `https://`). Panel appears from the first query character.
- **Commit keys**: Tab and Enter both insert (Slack behavior; Tab was the explicit ask). Consumed
  by the tap so the target app never sees them. `:name:` typed in full commits instantly.
- **Replacement**: N+1 backspaces (colon + query) then the emoji as a `keyboardSetUnicodeString`
  event, chunked at 16 UTF-16 units for multi-codepoint emoji. No clipboard involvement, so the
  user's clipboard is never clobbered.
- **Dismissal**: Esc, space/punctuation, modifier chords, mouse clicks, app switches. When in
  doubt, dismiss and pass the keystroke through — the app must never eat normal typing.
- **Failure posture**: every guard failure returns "pass the event through". Worst case the app
  does nothing; it should never make typing worse.
- **Per-app exclusions**: the idle→active transition asks `NSWorkspace` for the frontmost app's
  bundle ID and refuses to arm if it's excluded — one cheap check per typed `:`, and nothing else
  needs gating since every other action requires an armed session (app switches already reset).
  Exclusion seeding happens only when the defaults key is absent, so user removals stick.
  App-level only: browser tabs (e.g. github.com's own autocomplete) can't be distinguished.
- **Data**: gemoji `db/emoji.json` reduced to `[{e, a}]` (64KB), plus a few Slack-style aliases
  (`thinking_face`, `simple_smile`, `thumbs_up/down`, `100`). Entries without a unicode emoji
  (GitHub-custom like `:octocat:`) are dropped.

## Testing

- `--selftest` runs headless assertions on `EmojiIndex` (exact/prefix/dedupe/limit) — runnable in
  CI or after any build without GUI or permissions.
- The tap/panel/typist path needs the Accessibility grant, so it's verified manually: type
  `:tad⇥` in Notes, Slack, a browser, and a terminal.
