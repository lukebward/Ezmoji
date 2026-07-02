# Ezmoji

System-wide `:shortcode:` emoji autocomplete for macOS, Slack/Discord style. Type `:` followed by a
few letters in **any app**, a small picker pops up next to your cursor, and **Tab** (or Enter)
inserts the emoji.

```
you type:   this is great :tad⇥
you get:    this is great 🎉
```

## Build & install

```sh
./build.sh
cp -r build/Ezmoji.app /Applications/   # optional but recommended
open /Applications/Ezmoji.app
```

Requires Xcode command line tools (`swiftc`). No other dependencies.

## First-run permission

The app watches keystrokes globally, which macOS gates behind Accessibility:

1. On first launch you'll get a prompt — or open **System Settings → Privacy & Security →
   Accessibility** yourself.
2. Add / enable **Ezmoji**.
3. That's it. The app picks up the grant automatically within a couple of seconds (no relaunch
   needed). If typing still doesn't insert, also check **Privacy & Security → Input Monitoring**.

The menu bar icon (🙂 face) shows permission status and has Pause / Launch at Login / Quit.

## Usage

- `:smi` → picker appears after the first letter, filtered as you type
- **Tab** or **Enter** — insert the highlighted emoji
- **↑ / ↓** — move the highlight
- **Esc** — dismiss
- Typing the full closing colon (`:tada:`) inserts immediately, no Tab needed
- Space or any non-shortcode character cancels quietly

Shortcode names are the standard [gemoji](https://github.com/github/gemoji) set (what GitHub and
Discord use, and mostly what Slack uses): `:joy:`, `:+1:`, `:fire:`, `:eyes:`, `:rocket:`,
`:thinking_face:`, … ~1,900 aliases total, bundled in `Resources/emoji.json`.

## Per-app exclusions

Apps that already have their own `:emoji:` autocomplete are excluded out of the box — Ezmoji
stays completely dormant in them:

- **Chat**: Slack, Discord (+ PTB/Canary), Telegram (both variants), WhatsApp, Signal, Microsoft
  Teams (new + classic), Element, Mattermost, Rocket.Chat, Zulip, Beeper
- **Productivity / dev**: Notion, Figma, Linear, ClickUp, Asana, GitHub Desktop

Deliberately *not* excluded: **Zoom** (its emoji shortcodes have no keyboard autocomplete), and
editors like VS Code / Cursor / Zed / Obsidian (no native support, or plugin-only) — Ezmoji is
useful there.

- Menu bar → **Disable in ‹App›** — toggles Ezmoji for whatever app you were just using
- Menu bar → **Excluded Apps** — lists all exclusions; click one to re-enable Ezmoji there
- The list persists across restarts (`defaults` domain `dev.lukeward.Ezmoji`, key `excludedApps`)

Exclusions are per-app, not per-site: browsers count as one app, so GitHub's in-browser
autocomplete will overlap with Ezmoji's unless you exclude the whole browser.

## Quirks & limitations (by design — this is the simple version)

- **A `:` only arms the picker after a word boundary**, so `std::vector` and `https://` don't
  trigger it.
- **Password fields**: macOS Secure Input blocks event taps, so the app is automatically inert
  there. Same reason it can't leak your passwords.
- **Rebuild permissions**: `build.sh` signs with your Apple Development certificate when one
  exists, so the Accessibility grant survives rebuilds. With no certificate it falls back to
  ad-hoc signing, and each rebuild then needs the grant toggled off/on again.
- **Insertion mechanism**: it deletes the `:query` you typed (synthetic backspaces) and types the
  emoji as a unicode keystroke. Works in native apps, browsers, Slack, Discord, terminals. If some
  exotic app misbehaves, Esc and move on.
- No skin-tone variants, no frecency ranking, no custom emoji. It's ~550 lines on purpose.

## Verify the matcher without launching

```sh
build/Ezmoji.app/Contents/MacOS/Ezmoji --selftest
```

## Prior art

If you outgrow this, [Rocket](https://matthewpalmer.net/rocket/) is a polished free app that does
the same thing with more features. This exists because building it was half the fun.
