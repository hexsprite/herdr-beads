# Beads Popover

Ctrl-click a [beads](https://github.com/steveyegge/beads) issue ID in any Herdr
pane and get its details in an overlay pane, without leaving what you were doing.

The overlay is recursive: bead IDs inside it are themselves clickable, so you can
walk a dependency tree by clicking through blockers.

## Install

```sh
herdr plugin install hexsprite/herdr-beads
```

Requires `bd` on `PATH`, plus `perl` and `jq` (both ship with macOS and most
Linux distributions).

## How it works

Herdr detects hyperlinks in pane output and routes Ctrl-clicks matching a
plugin's `pattern` to that plugin instead of the browser. This plugin claims
URLs under `bead.invalid`:

```
https://bead.invalid/skills-0ud
```

`.invalid` is reserved by [RFC 2606](https://www.rfc-editor.org/rfc/rfc2606),
so it can never resolve. If the plugin is disabled or missing, the click fails
closed rather than opening some stranger's website.

## Making IDs clickable

The plugin handles clicks; something still has to emit the links.

**Agent output** — tell your agent to write IDs as markdown links. In
`CLAUDE.md`, `AGENTS.md`, or equivalent:

```markdown
When referencing a bead by ID, write it as a markdown link:
[skills-0ud](https://bead.invalid/skills-0ud) — never bare text.
```

**`bd` output** — `bd` prints bare IDs, which Herdr cannot see. Either pipe it
through the same rewrite this plugin uses internally, or patch beads to emit
[OSC 8](https://gist.github.com/egmontkob/eb114294efbcd5adb1944c9f3cb5feda)
hyperlinks when stdout is a TTY.

## Working directory matters

`bd` resolves its database from the working directory. The plugin launches the
pane in the clicking pane's cwd, so an ID clicked from a pane inside its own
repo resolves; the same ID clicked from an unrelated pane will not. The pane
says which directory it used rather than failing silently.

The cwd comes from Herdr's plugin context when it is present, and otherwise
from the session's focused pane — clicking a link focuses its pane, so that is
the click's origin.

## Why overlay and not popup

Popup panes are session singletons. A second `plugin pane open` while one is
on screen fails with `popup already open`, and the error goes to the plugin log
where nobody sees it — so every click after the first would appear to do
nothing. Overlays are ordinary panes, so the handler closes the previous one
and opens a fresh one. That is what makes clicking through a dependency tree
work.

## Configuration

`BEADS_POPOVER_CWD` forces the working directory, bypassing detection. Useful
for testing the handler outside a real click.

Herdr's context payload is written to `last-context.json` in the plugin root on
every invocation — it is undocumented and has changed shape between versions,
so having the last one on disk is worth the single file.

## License

MIT
