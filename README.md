# Task Tracker

A task list for the macOS menu bar. Tasks are sorted into In Progress, Todo, Deferred and Done, can be grouped into folders, and can hold links, images and reminders.

<p>
  <img src="screenshots/dark.png" width="400" alt="Task list in dark mode">
  <img src="screenshots/light.png" width="400" alt="Task list in light mode with a task selected">
</p>

## Install

Needs macOS 14 and Swift 6.

```sh
./scripts/build-app.sh --install
```

This builds the app, copies it to `/Applications` and starts it. Without `--install` it only builds `build/Task Tracker.app`.

## Keys

| Key | |
| --- | --- |
| ⌃⌥T | Open or close the list |
| Return | Add a task, or rename the selected one |
| ⌘Return | New line |
| Space | Mark done |
| ⌘1 – ⌘4 | Move to In Progress, Todo, Deferred, Done |
| ⇧⌘N | Put the selected tasks into a new folder |
| ⌫ | Delete |
| ⌘Z | Undo |

Drag to reorder or move between sections. Paste or drop images and links onto a task. Right-click a task to set a reminder.

## The menu

While an agent builds something, the **Menu** tab holds what you can do by hand in the meantime: the
checks the agent couldn't verify itself, and the ideas it left out of scope, grouped by PR. Only the newest
PR with something left to do is expanded; the others show as one line with their counts. A PR you expand or
collapse yourself stays that way, and its header stays at the top while you scroll through its items.

- **Agents fill it.** A Claude Code hook (below) notices `gh pr create` and tells the agent to add its
  checks and ideas with `menu add`. It also remembers the session, so a fix can go back to it.
- **You decide each item.** A check: **Works**, or **Problem…**, which becomes a comment on the PR while
  it's open (the fix lands in that PR) and a new issue once it's merged. An idea: **Make issue**,
  **Later** or **Dismiss**. Right-click an item for all of these, plus **Dismiss** and **Delete** for
  checks too; right-click a PR to delete everything on it. Dismissed items are remembered so they aren't
  proposed again, deleted ones are gone. ⌘Z takes back a status change or a delete.
- **Fix in its session** sends the problems on a PR to the session that built it, in Ghostty: typed into
  its tab if it's still open, resumed in a new tab if not. The agent fixes them and puts each check back
  with `menu reopen`.

`menu help` lists every command. The app's buttons do the same as the commands.

### Setup

`./scripts/build-app.sh --install` also installs `menu` to `~/.local/bin`. Then add the hook to
`~/.claude/settings.json`:

```json
"PostToolUse": [
  { "matcher": "Bash", "hooks": [{ "type": "command", "command": "~/.local/bin/menu hook", "timeout": 15 }] }
]
```

To put new issues on a project board, add the repo to `menu-config.json` next to the data file:

```json
{ "projects": { "owner/repo": {
  "owner": "owner", "number": 4, "projectId": "PVT_…", "statusField": "PVTSSF_…", "statusOption": "<Backlog option id>"
} } }
```

The first **Fix in its session** asks whether Task Tracker may control Ghostty.

## Data

Tasks are saved to `~/Library/Application Support/TaskTracker/tasks.json`, images to the `attachments` folder next to it, the menu to `menu.json`.

## Development

```sh
swift test
swift build && TASKTRACKER_DATA=/tmp/tasks.json .build/debug/TaskTracker
```
