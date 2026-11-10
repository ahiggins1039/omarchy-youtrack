# al.youtrack

An Omarchy bar widget for the YouTrack tickets assigned to you.

The bar shows the collapsed state only — one `P<n>:<total>` pair per priority
that has open tickets, e.g. `P0:1 P1:4 P2:7`. The pill takes the theme's urgent
color while any P0 is open, and reads `YT!` when the lookup fails. Clicking
opens a popup listing the same tickets under a heading per priority, newest
update first.

## Interactions

| Input | Action |
|---|---|
| Left click | Open/close the popup |
| Right click | Refresh now |
| Middle click | Open the query in YouTrack |
| `↑` / `↓` in the popup | Move the cursor over tickets |
| `Enter` | Open the highlighted ticket in the browser |
| `/` or click the search box | Search the list |
| `Shift+Enter` in the search box | Search all of YouTrack |
| `r` | Refresh |
| `Esc` | Close |

## Search

The box at the top of the popup filters the listed tickets as you type. Every
word has to match somewhere in the ticket's id, summary, priority, state, type,
or project, case-insensitively, so `p1 bug` narrows to P1 bugs and `sys-12`
finds a ticket by id. The bar counts always cover the full query.

While the box has focus, `↑` / `↓` move through the matches (the top one is
highlighted as you type), `Enter` opens the highlighted ticket, and `Esc`
clears the search, or closes the popup if it is already empty. The search is
reset each time the popup opens.

### Searching YouTrack itself

To look beyond your own tickets, press `Shift+Enter` (or plain `Enter` when
nothing assigned matches), or click the "Search all of YouTrack" row under the
list. The box's text is then sent to YouTrack as the query itself, so it can be
plain words (a full-text search across every project, resolved tickets
included) or full query syntax such as `project: SYS #Unresolved Type: Bug`.
The results replace the list, grouped by priority as usual, and the bar is
left alone.

Editing the text drops back to filtering your own tickets until you search
again; typing it back to exactly what was searched brings the last results
back without asking YouTrack again. With YouTrack's results showing, `Shift+Enter` or the row opens the same
search in the browser. A query YouTrack cannot parse shows its error in place
of the results.

## Colors

Each priority takes a color from the active theme's `colors.toml`, in both the
bar pill and the popup's section headings:

| Priority | Palette role | Falls back to |
|---|---|---|
| P0 | `red` / `color1` | the bar's urgent color |
| P1 | `yellow` / `color3` / `orange` | the theme accent |
| P2 | `green` / `color2` | the theme accent |
| P3 | `blue` / `color4` / `cyan` | the theme accent |
| P4 | `muted` / `color8` / `dark_foreground` | `Color.muted` |

Anything outside P0-P4 keeps the surrounding foreground color. `colors.toml` is
watched, and re-read whenever the shell's own palette changes, so a theme switch
should repaint the widget without a restart.

## Credentials

`~/.config/omarchy/youtrack.env` (mode 600):

```sh
YOUTRACK_URL="https://example.youtrack.cloud"
YOUTRACK_TOKEN="perm:..."
YOUTRACK_QUERY="for: me #Unresolved"
```

The token is a YouTrack permanent token (Profile → Account Security →
Authentication → New token). Point `YOUTRACK_CONFIG` somewhere else to use a
different file.

## Settings

Per-widget settings live in the widget's entry in `~/.config/omarchy/shell.json`
and override `YOUTRACK_QUERY`:

- `query` — any YouTrack search (default `for: me #Unresolved`)
- `refreshIntervalSec` — poll interval, minimum 30 (default 300)
- `emptyLabel` — bar text when nothing matches (default `YT:0`)

Note that `#Unresolved` is about the resolved flag, not the workflow state, so
states such as `Released` still count. To leave them out:

```
for: me #Unresolved State: -Released
```

## Layout

`youtrack-fetch` is a standalone script: run it in a terminal to see exactly
what the widget sees, including its error JSON. `Model.js` holds the grouping,
label, and formatting logic; `Panel.qml` is the bar pill plus the popup.

## Editing it

Saving `Model.js` or `Panel.qml` reloads the plugin registry but leaves the
widget already mounted in the bar running the previously compiled QML, so a
change to the pill or the popup only appears after `omarchy restart shell`.
Changes to `youtrack-fetch` take effect on the next refresh.
