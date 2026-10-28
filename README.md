# Clipboard history for Omarchy

A Raycast-style clipboard history for the [Omarchy](https://omarchy.org) shell.

It reads the history Omarchy already records, so everything copied with
Super+C, Ctrl+C or any app shows up with nothing else to install or run. On
top of that it adds pins, type filters, names, editing, OCR and QR text,
source app and copy counts, deletion by time window, retention, and ignored
apps.

## Install

```bash
omarchy plugin add https://github.com/dvrshil/omarchy-clipboard-history.git --enable
```

It adds a clipboard icon to the bar (default section: right). Left click
opens the history, right click opens it filtered to images.

### Keyboard shortcut (optional)

The plugin doesn't bind any key unless you ask it to. Pick one of these:

- **Let the plugin manage it.** Set **Shortcut** in the widget's settings, or
  add `"shortcut"` to its entry in `~/.config/omarchy/shell.json`:

  ```json
  { "id": "dvrshil.clipboard", "shortcut": "ALT + V" }
  ```

  The plugin backs up `~/.config/hypr/bindings.lua`, writes one marked block,
  and reloads Hyprland. Changing the setting rewrites that same block.

- **Bind it yourself** in `~/.config/hypr/bindings.lua`:

  ```lua
  o.bind("ALT + V", "Clipboard history", { panel = "dvrshil.clipboard" })
  ```

Or summon it from anywhere: `omarchy-shell shell toggle dvrshil.clipboard`.

## Using it

| Key | Action |
|---|---|
| Type | Search content and custom names |
| ↑ / ↓, Ctrl+N / Ctrl+J, PgUp / PgDn | Move |
| Enter | Primary action (paste to the active app by default) |
| Ctrl+Enter | Secondary action (copy only by default) |
| Ctrl+1 … Ctrl+9 | Paste that entry |
| Ctrl+K | Action panel (searchable) |
| Ctrl+P, Ctrl+Tab | Cycle type filter: Text, Images, Files, Links, Emails, Colors |
| Ctrl+. (or Ctrl+Shift+P) | Pin / unpin |
| Ctrl+Shift+↑ / ↓ | Reorder pins |
| Ctrl+E | Rename entry |
| Ctrl+Shift+E | Edit content (Ctrl+S saves) |
| Ctrl+O / Alt+Enter | Open (links in the browser) |
| Ctrl+Shift+O | Show in Files |
| Ctrl+T | Copy text from image (OCR) |
| Ctrl+Shift+S | Share via LocalSend |
| Ctrl+X | Delete entry |
| Ctrl+Shift+X | Delete all (pins are kept) |
| Esc | Clear search, then filter, then close |

The action panel also has **Copy Text from QR Code** and **Delete entries
from the last 5 / 15 / 30 minutes, hour, or 24 hours**.

The detail pane shows a preview (colour swatch, image, or text) and the
source app, content type, characters, words, lines, image size, times
copied, and first and last copied. Entries that were already in the history
when the plugin was installed show "Before tracking began".

## Settings

| Setting | Default | |
|---|---|---|
| `shortcut` | *(empty)* | Optional Hyprland chord; see above |
| `primaryAction` | `Paste to active app` | Or `Copy to clipboard` |
| `keepHistoryFor` | `3 Months` | `1 Day` … `1 Year`, `Unlimited`. Pins are never removed |
| `ignoredApps` | `1password, bitwarden, keepassxc` | App ids; copies made while one is focused are dropped |

Omarchy's own capture already skips copies that password managers mark as
sensitive.

## Files and dependencies

- Reads and writes Omarchy's history at
  `~/.local/state/omarchy/clipboard-history.json` (requires the stock
  `omarchy.clipboard` plugin to be enabled, which is the default).
- Keeps its own metadata (pins, names, counts, source apps) in
  `~/.local/state/omarchy/dvrshil-clipboard/state.json`.
- Uses tools that ship with Omarchy: `wl-clipboard`, `wtype`, `jq`,
  `xdg-open`, `notify-send`, `omasnap`, `omarchy-menu-share`.
- Optional: `tesseract` for OCR, `zbar` (`zbarimg`) for QR codes. Both are
  installed on a stock Omarchy system; the actions show a notice if missing.

Clipboard content is only ever displayed as plain text and passed to helper
commands through stdin or as single arguments, never through a shell string.

## Uninstall

```bash
omarchy plugin remove dvrshil.clipboard
```

If you set a Shortcut, also delete the block between
`-- >>> dvrshil.clipboard shortcut` and `-- <<< dvrshil.clipboard shortcut`
in `~/.config/hypr/bindings.lua` and run `hyprctl reload`. To drop the
plugin's metadata: `rm -r ~/.local/state/omarchy/dvrshil-clipboard`. Your
clipboard history itself belongs to Omarchy and is left in place.

## Development

```bash
node --test tests/                 # model tests
omarchy plugin validate .          # manifest check
```

Saved changes under `~/.config/omarchy/plugins/` hot-reload.

## License

MIT
