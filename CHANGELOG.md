# Changelog

All notable changes to Tamio are documented in this file. The format is based
on [Keep a Changelog](https://keepachangelog.com); versions follow semver.
Each release's notes come from its section here: on the GitHub release, and in
the update window that offers it. A tag with no section here is not built.

Write new entries under **Unreleased**, as **Added**, **Changed**, **Fixed** or
**Removed**, each item opening with a bold phrase that says what changed for
the user. To release, rename that heading to the version and date
(`## [0.2.0] - 2026-11-02`), set `MARKETING_VERSION` to match, and tag
`v0.2.0`.

## [Unreleased]

## [0.2.5] - 2026-10-19

### Added
- **Settings sync between your Macs.** Light or dark, the terminal's whole
  configuration (fonts, colours, cursor, keys) and font size, the session
  switches, hidden files, the connection timeout, and live status with its
  refresh now go through iCloud sync like your servers do, under the new
  Settings switch in iCloud Sync. Each setting keeps its latest change, so
  changing the font on one Mac and the theme on another keeps both. Whether
  the MCP server runs, the agents allowed to act without asking, and update
  checks stay with each Mac.
- **Paste files to upload them.** Copy files or folders in Finder, then press
  ⌘V in a server's pane in Files: they upload to the folder it shows, like a
  drop. In the Mac's pane, ⌘V copies them there. The server's pane takes the
  keyboard when Files opens; a click among the files gives it to a pane.
- **Files follows the terminal's folder.** Turn on Shell integration in Edit
  Server › Advanced, and each new terminal on that server reports its folder
  at every prompt; switching to Files then opens the folder the terminal was
  last in, and the pane's Actions menu has Go to Terminal's Folder. It works
  with bash, zsh and fish, lasts only for the session and changes nothing on
  the server. A server whose shell reports its folder by itself needs no
  switch. Browsing elsewhere in Files stays put until the terminal moves.

### Fixed
- **Terminals open on JumpServer bastions.** A JumpServer (Koko) bastion
  closed the session right after signing in, because Tamio sent the window
  size before asking for a shell and the bastion never answered. The size now
  follows the shell, so its asset menu appears. When a server refuses the
  terminal or the shell, the terminal now says so instead of only Connection
  Closed.

## [0.2.4] - 2026-10-18

### Added
- **A proxy command for a server.** In Edit Server › Advanced, a Proxy command
  field carries the connection through a command instead of directly to the
  address, the way ssh_config's ProxyCommand does: a Cloudflare Access tunnel
  is `cloudflared access ssh --hostname %h`, where `%h` is the address and
  `%p` the port. Terminals, SFTP, live status, port forwards, snippets and
  agent commands all go through it, and a command that fails to start says
  why. It is kept with the server and synced. Left empty, the server connects
  directly, as before.

### Fixed
- **The group switcher no longer flashes on a click.** Choosing a group, or
  clicking the one already chosen, showed a large glass lens and snapped the
  selection back for a moment; the selection now slides to the new group, and
  the server cards stay put instead of animating as the list changes.

## [0.2.3] - 2026-10-18

### Added
- **Home shows one group at a time.** A switcher at the top left of the
  toolbar, beside search and New Server, lists All, every group a server is
  in, and No Group for the servers in none; a click shows only that group's
  cards, and the choice is kept for the next launch. It appears once a
  server has a group.

## [0.2.2] - 2026-10-18

### Changed
- **New Server starts on the first SSH key.** With a key in Identities, the
  dialog opens with SSH key chosen and the first key picked; a password is a
  click away. With no key yet it starts on Password, as before.

### Fixed
- **A right-click anywhere on a session row opens its menu.** The menu
  answered only a click on the row's text or symbols; the space between
  them, and above and below, did nothing.

## [0.2.1] - 2026-10-18

### Added
- **A notice when the keychain keeps the key back.** If macOS does not hand
  Tamio its master key (the "wants to use your confidential information"
  prompt denied, or a differently signed copy of Tamio), the sidebar says so
  and what to do, instead of the app looking empty; nothing is written until
  the key is back.

### Changed
- **Session rows in the sidebar start with the server's name.** The server
  symbol before it is gone, so a long name has the room; the whole name is in
  the row's tooltip.

### Fixed
- **Home's first card spans the page.** With no server saved yet, the card
  stopped at 640 points and left the rest of the page empty.

## [0.2.0] - 2026-10-18

### Added
- **A snippets panel beside every terminal.** The toolbar's Snippets button
  (⌥⌘S) opens a panel of the saved snippets: a click types one at the prompt
  and runs it, and its menu inserts it without running, copies it or edits
  it. New snippets can be made there too.
- **Paste protection asks first.** With Paste protection on (Settings ›
  Mouse & Clipboard), pasting text with line breaks or control characters
  into a terminal shows the text and asks before pasting it; before, it was
  pasted at once.
- **VoiceOver reads the sidebar and the server cards.** Every sidebar row and
  every card on Home has a name and can be pressed.

### Changed
- **Tamio is a native Mac app.** It is built on AppKit instead of Mac
  Catalyst: the toolbar, sheets, alerts, open panels, menus and the menu bar
  item are the Mac's own, the update window is Sparkle's, and the app is one
  bundle without a plugin. Servers, identities, snippets, settings and the
  master key carry over.
- **The changelog is organised by kind of change.** Added, Changed, Fixed and
  Removed, as in Keep a Changelog, instead of by area of the app; the update
  window shows the same.
- **Terminal pages end level with the sidebar's Settings row,** with the
  connection line in a slim strip under the terminal; Home's inspector ends
  on the same line.
- **Terminal text keeps its distance from the edges.** Every terminal, the
  batch run sheet's included, starts with 12 points of padding at the sides
  and 10 above and below, instead of Ghostty's 2; Settings › Window › Padding
  still sets it.

### Fixed
- **The batch run sheet shows a server as done the moment it finishes.** It
  stopped redrawing once the last server finished, so the count and the
  states stayed stale until something else redrew it.
- **The batch run sheet's output no longer sits in a dark frame** in light
  mode; the terminal draws its own background.

### Removed
- **The Recent settings** (remember recent servers, number to keep, Quick
  Connect commands): nothing on the Mac showed recent servers, so the
  switches changed nothing.
- **Hide the mouse while typing**, from Terminal › Mouse & Clipboard: the
  embedded terminal never hid it.

## [0.1.4] - 2026-10-18

### Changed
- **The group badge follows the server name** in the server list, so every
  name starts at the same edge.
- **The window cannot be made smaller than 960 by 640 points.** One restored
  smaller grows to that, so the sidebar's Settings row is never cut off.

### Fixed
- **The sidebar's collapse button no longer drops to a second row, and the
  server cards no longer flicker.** Catalyst dropped the window's toolbar
  whenever the window sat exactly at the content's minimum size, and the app
  then rebuilt its pages twenty times trying to get it back, which faded every
  card in again each time. Neither happens now.
- **A server whose connection died while the Mac slept keeps its readings.**
  Its card no longer blanks; it is reconnected within a second.
- **The update window shows release notes as text,** not as HTML markup.

## [0.1.3] - 2026-10-18

### Added
- **Tamio installs with Homebrew:** `brew install --cask owo-network/brew/tamio`.

### Fixed
- **Agent activity never cuts a command off.** A short command shows whole; a
  longer one, or a task's steps, shows behind a click.

## [0.1.2] - 2026-10-18

### Added
- **A server with several terminals lists each one in the sidebar,** under the
  server. Right-click a session to duplicate a terminal, reconnect or close it.
- **Hidden files can be shown or hidden,** in Settings › General › Files or a
  pane's Actions menu. They are hidden unless you turn them on.

### Changed
- **A server's Files pane opens in the home folder** of the user Tamio signs
  in as, not at the root of the disk.
- **Containers and processes show their last reading at once** and refresh
  behind it; containers list before their figures arrive.
- **Disks leave out system mounts:** container layers, snaps, memory
  filesystems, Time Machine snapshots and the system's own volumes, and each
  disk shows once.
- **The panel names its server on a row of its own.**

### Fixed
- **Files can be left again.** The Terminal · Files · Monitor switcher is on
  the Files page too; it had gone missing there.
- **A click on a server card shows its server at once,** and the cards no
  longer stutter as the panel opens.

### Removed
- **The tab bar above the terminal.** The sidebar lists the terminals instead.
- **The built-in editor.**

## [0.1.1] - 2026-10-18

The first release of Tamio, an SSH client for the Mac.

### Added
- **Servers.** New Server is a dialog: address, label, group, tags, username
  and port, then a password or an SSH key. An empty username signs in as
  `root`. The server list shows each server's group as a badge, with live CPU,
  memory, disk and network.
- **Identities.** Paste a key, load it from a file, or generate an Ed25519 key.
  A private key is never shown again once saved.
- **Home.** A card for every server with live CPU, MEM and DISK, the operating
  system's logo, and a country flag for labels such as `JP Tokyo`. Select a
  card for its details: overview, processes, containers and agent activity.
  Search and New Server sit in the toolbar.
- **Files.** Two panes, this Mac and the server, each switchable to any
  server. Drag files between the panes or from Finder to copy them; folders go
  whole. Drag a file from a server to Finder to download it. Transfers run in a
  queue with progress, speed, time left, cancel and retry, and a notification
  tells you when one ends while Tamio is in the background.
- **Agents (MCP).** Claude Code, Codex and other MCP clients can list your
  servers and their live status, and, once you approve, run commands and
  manage servers, keys, snippets and port forwards. Agents never see passwords
  or private keys. What agents do is recorded per server, under the server's
  Activity: an agent names the task each step serves ("Install nginx"), and
  all the steps of a task are one entry, with each step and its result under
  it. Settings › MCP turns the server on or off, sets up Claude Code, Codex and
  the Tamio skill, and filters the activity by server.
- **Approvals once, for an hour, or always,** for agents that work alone while
  you are away. Always-allowed agents are listed in Settings › MCP, where they
  can be revoked.
- **iCloud sync, on unless you turn it off,** so what agents did on your
  servers is not lost with a Mac. Servers, identities, snippets, port forwards
  and known host keys stay the same on all your Macs, end-to-end encrypted
  under a passphrase only your devices know. Tamio makes it and keeps it in
  iCloud Keychain; Settings shows it for a device without iCloud Keychain.
  Agent activity from every Mac is kept together.
- **Updates itself.** A new version shows at the bottom of the sidebar, with
  its release notes in the update window.
- **A new icon:** a glass terminal window, its prompt followed by an agent's
  typing dots, in front of the servers it works on.

### Changed
- **Switching between light and dark is smooth.**
- **Settings never squeeze a title into a narrow column:** a wide control moves
  under its title instead.
