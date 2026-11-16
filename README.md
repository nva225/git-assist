# Git Assist

A menu bar app that keeps an eye on your GitHub PRs: popups at the top of whichever screen you're
working on, plus a fast, locally cached list and search of every PR in the watched repos.

## Install

Requires macOS 14 or later.

```bash
xcode-select --install        # Apple's command line tools (swiftc); skip if already installed
brew install gh               # GitHub CLI
gh auth login                 # sign in; Git Assist reuses this login
git clone https://github.com/nva225/git-assist.git
cd git-assist
./run.sh --show
```

`run.sh` builds the app, copies it to `~/Applications/GitAssist.app`, and launches it. It lives in
the menu bar. On first launch the main window asks which repositories to watch, suggesting the ones
you've recently opened PRs in, reviewed, or pushed to; change them later in Preferences → General.
The first sync indexes each repo's full PR history in the background, which can take a few minutes.

Built locally, the app is never flagged as downloaded, so Gatekeeper doesn't block it. No special
macOS permissions are needed.

```bash
./run.sh          # rebuild, install, relaunch (run again after git pull)
./run.sh --show   # same, and open the main window
./build.sh        # build only -> build/GitAssist.app
```

## Main window — ⌃⌥G (configurable)

The toggle has three modes; ⇥ / ⇧⇥ with an empty search box steps through them.

- **Open** — open, non-draft PRs that involve you, uncapped, in the sections below.
- **All** — the same sections plus closed and merged PRs and your team's other PRs. In each section the
  open PRs always show first, then a "merged & closed" divider and the most recent finished ones, dimmed
  and capped (10 by default; Preferences → General, 5–20).
- **Recent** — the 40 PRs from All with the newest activity, grouped Today / Yesterday / Earlier this week
  / Older. Each shows its latest two happenings (comment, approval, push, merge…); click one to open it.
  Good for getting back to something after dismissing its popup.

Row icons are colored by state, as on GitHub: green open, purple merged, red closed.

Sections:

| Section | Meaning |
| --- | --- |
| Needs my review | You're a requested reviewer and haven't commented or reviewed since the request. Sorted by deadline. |
| My PRs | Yours, with approval / changes-requested counts and who it's still waiting on. |
| I've commented | You've commented or reviewed (not approved). Stays here after you comment. |
| I've approved | Dimmed, with a ✓. Flags new commits pushed since your approval. |
| Mentioned or assigned | You're @-mentioned or assigned, but haven't taken part. |
| Other team PRs | All mode only: everything else by the authors in Preferences → Team. |

A blue **N new** chip counts comments and reviews from others since your last comment, or since you
last opened the PR from Git Assist.

### Search

Typing searches every cached PR (open, closed, and merged). Free text matches the number, title, branch, author, description, and
comments, ranked in roughly that order. Comment matches show an excerpt; click it to open that comment.

| Qualifier | |
| --- | --- |
| `author:` | opened the PR |
| `commenter:` | commented on or reviewed it |
| `comment:` | text in a comment, by the `commenter:` if one is given |
| `title:` `body:` `branch:` `label:` | text in those fields |
| `reviewer:` `approved-by:` `involves:` | review involvement |
| `is:` | `open` `closed` `merged` `draft` `all` `mine` `needs-review` `requested` `approved` `commented` `overdue` `mentioned` |

`me` (or `@me`) works anywhere a login does, `-` negates (`-author:dependabot`), and quotes group
words (`comment:"feature flag"`). For example, `commenter:me comment:migration` finds the PR where you
said something about a migration.

Keys: **Tab** completes the suggestion (qualifier names, then logins / values), **↑↓** move through
suggestions or results, **Return** opens the selected PR, **Esc** hides suggestions → clears → closes.

## Popups

One bar per PR, stacked top-center on the screen that has the focused window. New activity on the same
PR updates its bar instead of adding another. They stay until clicked (opens the PR or comment) or
dismissed with ×. After 8 seconds untouched, the stack fades translucent and collapses into a deck behind
the newest card, which stays put (up to three edges peek out below it, plus an "N more" tag). Hovering
fans them back out at full opacity, and so does any new popup. Like unread mail, open popups are saved
(`popups.json`) and come back after a restart. The **Snooze** pill under the expanded stack (or the menu
bar's Snooze Popups submenu) hides everything for 15m / 1h / 2h. New activity keeps collecting silently,
the menu bar icon turns into a moon, and the stack comes back expanded when the time's up. Per type
(approvals, comments on mine, review requests, replies where I commented, deadlines), you can turn
them off or make them auto-hide in Preferences → Popups.

## Review deadline

Counted in business days (weekends excluded) from when you were requested, re-requested, or the PR left
draft. Commenting or reviewing stops the clock. Amber after 1 day, red after 2, with a popup at each
mark. Both are configurable.

## Data

Cache lives in `~/Library/Application Support/GitAssist/`. On first launch, open PRs sync in seconds,
then the full history (titles, bodies, all human comments; bot comments are dropped) is indexed in the
background. That takes a few minutes and resumes if interrupted. After that, each poll lists open
PRs and refetches only the ones that changed, with a full refresh every 5 minutes. Preferences →
General → Rebuild throws the cache away.
