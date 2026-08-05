# Beads Popover

Ctrl-click a [beads](https://github.com/steveyegge/beads) issue ID in any Herdr
pane and get its details in a popup, without leaving what you were doing.

The popup is recursive: bead IDs inside it are themselves clickable, so you can
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
popup in the clicking pane's cwd, so an ID clicked from a pane inside its own
repo resolves; the same ID clicked from an unrelated pane will not. The popup
says so explicitly rather than failing silently.

## Configuration

Set `BEADS_POPOVER_DEBUG=1` to dump Herdr's context JSON to `last-context.json`
in the plugin root — useful when Herdr changes context shape between versions.

## License

MIT
