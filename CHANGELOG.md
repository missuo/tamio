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

### Added
- **Tamio tells you when it blocks a program's copy to the clipboard.** A
  program in the terminal, such as tmux or Neovim on a server, can ask to copy
  text with OSC 52. Tamio blocks this, and used to do it silently, so the
  program said "Copied" while the clipboard kept what it had. A notice at the
  top of the terminal now says the copy was blocked, without showing the
  text, and **Allow Once** lets the latest copy through. Closing the notice
  keeps it away for 30 seconds. **Let programs copy to the clipboard**, under
  Settings › Mouse & Clipboard, allows every copy; it is off unless you turn
  it on. Programs still can never read the clipboard.
- **Frosted glass, on by default.** The whole window is see-through: your
  desktop's colour comes through the blur, under a light neutral tint that
  keeps text readable over a white or a dark wallpaper alike, and grey text
  on glass is a step lighter (darker in Light mode) than on solid colour.
  Cards and the sidebar are a light tint over it instead of a solid fill, and
  the terminal's background is mostly see-through (opacity 0.3), the same
  glass as the window with a wash of its theme's colour. In Light mode,
  unless you picked a theme or colours of your own, the terminal takes a
  light theme (Apple System Colors Light), so it is a white wash over the
  glass with dark text rather than a dark one. Turn it off under
  Settings › Appearance › Frosted glass; macOS's Reduce transparency makes
  it solid too. A background opacity you set under Terminal stays as it is.

### Changed
- **One set of icons across the app.** Every icon (the sidebar, the
  toolbars, menus, Settings, cards and empty pages) is now Lucide's, drawn to
  one grid and stroke, as symbols that size with the text beside them as SF
  Symbols do, instead of SF Symbols of different weights. The sidebar's are a
  step softer than its titles and full ink on the selected row. The sidebar
  button keeps the Mac's own symbol, and a snippet's icon, which you pick,
  stays as it was.
- **The sidebar stays put, and the content slides over it.** The sidebar is
  a panel inset from the window's edge, with the window's buttons and the
  sidebar button on it. Hiding the sidebar slides the content's edge across
  to fill the window; showing it slides the edge back. The sidebar button is
  always in the same place, beside the window's buttons, and Home's group
  switcher sits in the toolbar, lined up with the cards. The sidebar has a
  fixed width.
- **No capsules around buttons.** The toolbar's buttons are plain symbols
  over the window, with no Liquid Glass capsule around each: the sidebar
  button, the search field (a flat field) and the rest. The one exception is
  each page's primary action, a small accent capsule that says “+ New”
  (its whole name, such as New Server, is its tooltip). Home's group switcher has no capsule track either.
- **A simpler Settings toolbar.** Only search is in it. Back and Forward are
  gone (the categories are always beside the page); Undo, Redo and Reset
  Terminal Settings (in the ⋯ menu) are beside a terminal category's title,
  where they apply. The live terminal preview no longer has a toggle: it is
  on the Text, Colors, Cursor and Window pages, beside the settings when
  there is room and above them when not.
- **The server editor's credentials line up.** The Password, SSH key and
  None switch is a row of its own, Sign in with, starting where the fields
  above it do, and the notes under a field start where the field does.
- **About Tamio reads in lines.** Tamio's copyright stands on its own, and
  below it, apart, what Tamio is based on: Rayon, with one copyright to a
  line.
- **Pages no longer scroll into the toolbar.** With the toolbar's capsules
  gone, a page scrolled up ran under its buttons and search field; it now
  fades out as it reaches the toolbar.
- **Acknowledgements list the contributors.** Settings › About ›
  Acknowledgements names everyone who has contributed to Tamio on GitHub, in
  place of the maintainer's name.
- **No address under the terminal.** The `user@host` line under every
  terminal is gone; the sidebar and the title already name the server. Live
  CPU and memory still show there while a monitor is open.

### Fixed
- **The Servers list scrolls smoothly.** With 60 servers, a third of the
  frames of a scroll came late. Each row and each of its three buttons
  tracked the pointer, so every frame tested hundreds of regions and drew the
  row under the pointer again; the list now tracks it once and moves a single
  highlight. Rows are drawn only when what they show changes, and only the
  ones in view are laid out.
- **The sidebar opens and closes smoothly.** The window's split view laid
  out its toolbar again at every frame of the slide, which took a sixth of
  each frame, and Home's group switcher slid its selection with an effect
  that followed its place in the window, so it was drawn and measured again
  at every frame too: Home ran at about 30 frames a second while the sidebar
  moved. The toolbar now stays still, the switcher's selection slides within
  it, and while the sidebar slides nothing on the page is tested for the
  pointer, which took a fifth of each frame with many servers.
- **Showing or hiding the sidebar keeps the columns.** The Servers list
  dropped a column, and Home a column of cards, when the sidebar opened. The
  columns are now chosen for the width with the sidebar open, so hiding it
  gives the names and the cards more room instead. The list's columns are
  also chosen as its rows are laid out, so the header and the rows agree at
  every width, and only the rows in view are laid out.

## [0.2.18] - 2026-11-05

### Changed
- **Copy Address copies only the host.** It used to add the port
  (`host:22`), which had to be trimmed off before pasting the address into
  anything else. Copy Command still includes the port when it isn't 22.

### Fixed
- **Programs on the server use all 256 colours.** Tamio told the server its
  terminal was a plain `xterm`, which has 8 colours, so shells such as zsh
  left out the rest: zsh-autosuggestions' grey suggestion looked just like
  the typed text. It now asks for `xterm-256color`.
- **Country flags keep their full width beside long server names.** On a
  card, in the server list and in the inspector, a long name squeezed the
  flag down to a thin sliver; the flag now stays whole.

## [0.2.17] - 2026-10-23

### Fixed
- **Servers saved before 0.2.16 connect again.** The SSH library 0.2.16
  brought in asks a server for its Ed25519 host key first, where the one
  before asked for ECDSA, so every server whose key Tamio had saved looked as
  if its key had changed and was refused as offline. Tamio now asks each
  server for the kind of key it has saved, as OpenSSH does, so saved keys
  keep working and none has to be forgotten.

## [0.2.16] - 2026-10-23

### Fixed
- **RSA keys sign in to current OpenSSH servers.** OpenSSH 8.8 and later
  refuse RSA signatures made with SHA-1, the only kind Tamio made. RSA keys
  now sign with SHA-256 or SHA-512 when the server takes them, whether the
  identity stores the key or an SSH agent such as 1Password holds it. The
  SSH library behind this is updated, with fixes for flaws a malicious
  server could use against the connection.

## [0.2.15] - 2026-10-23

### Fixed
- **A server can sign in with an SSH agent's key from its editor.** The Key
  picker lists identities that use an SSH agent next to stored keys, each
  named with its agent, such as 1Password. Editing a server that signs in
  through an agent keeps that identity instead of turning it into an empty
  password, and a sign-in the agent could not make says why, in the app's
  language.

## [0.2.14] - 2026-10-23

### Changed
- **Live status costs the server less.** A refresh used to hold the server
  for a second to sample its counters twice; now only the first refresh of a
  connection does, and the rates of every later one come from the previous
  refresh's sample, so a round is a single read with no wait. Linux reads
  only the cpu rows of /proc/stat (the interrupt row ran to tens of
  kilobytes on large servers), and the quiet sessions behind the server
  cards, the Servers table and the menu bar read the summary alone: no
  per-core rows, disk I/O, TCP counters, addresses or GPU probe. Those are
  read for the monitor page, and for the inspector while it is open.

### Fixed
- **Settings › MCP shows the whole prompt.** A settings row whose control
  is a block of wrapped text (the Prompt, and the two commands under Set Up
  an Agent) was laid out as tall as the text unwrapped, so the prompt ran
  past its card into Agent Activity and the Copy buttons sat on the
  dividers.
- **The sidebar stays put when the window is shrunk.** After Settings, or
  a terminal, Files or Monitor page, had been open in a larger window, the
  page kept out of sight held the window's content at that size, so
  shrinking the window from its left or bottom edge pushed the sidebar off
  the left edge and the Settings row off the bottom.

## [0.2.13] - 2026-10-21

### Added
- **A terminal reconnects by itself.** A server's terminal whose connection
  drops, or that could not connect, tries again three times, ten seconds
  apart, saying so in the terminal; after that it stays closed with
  Reconnect. A shell you exited, a session you closed, and a sign-in the
  server refused are left alone.

### Changed
- **Home's group switcher no longer offers No Group.** Servers in no group
  are under All; a choice of their own read as a group.

## [0.2.12] - 2026-10-21

### Fixed
- **Load from File… did nothing in New SSH Key.** The file picker is now
  attached to the sheet that is open instead of the window behind it, so it
  appears. (#12)

## [0.2.11] - 2026-10-20

### Fixed
- **0.2.10 could crash on launch or on Home.** The new card grid trapped
  when SwiftUI asked it for its ideal size with an unbounded width, which
  some windows do; the grid now treats any width no row of cards could have
  as one column.

## [0.2.10] - 2026-10-20

### Added
- **A terminal on this Mac.** File › New Local Terminal (⌘T), or New Local
  Terminal in a menu bar server's menu, opens your login shell in a Tamio
  terminal, with your Ghostty settings, listed under Sessions as This Mac.
  When the shell exits, New Shell starts another in its place.

### Fixed
- **The sidebar slides open smoothly, and the toolbar holds still.** Three
  things went wrong at once on macOS 26. The search field was the system
  one, which folded to an icon while the toolbar was briefly short of room
  mid-slide; it is now Tamio's own, which never folds. The sidebar button
  was AppKit's, which it moves into the sidebar's part of the toolbar
  partway through the slide and dropped into the » menu until the slide
  ended; it is now Tamio's own, in the content's part. And Home's cards were
  laid out again at every frame, with the OS line measured three ways and
  the buttons each time, so with live status on a frame took up to 100 ms
  and the sidebar jumped halfway; the cards now measure those once, and the
  grid moves cards instead of rebuilding rows. Cards also fill the row, with
  no space left over at the right. The 0.2.9 change that moved the page by
  an offset is gone: it made the cards jump instead.

## [0.2.9] - 2026-10-20

### Added
- **Sign in with keys an SSH agent holds.** An identity can now use an SSH
  agent instead of a stored key: the system agent, 1Password's, or any other
  socket such as Secretive's or gpg-agent's. The agent signs; the private key
  never comes into Tamio, and only the socket and, if you choose one, the key
  to offer are kept and synced. Edit an identity, choose SSH agent, and pick
  one of the agent's keys or let each be tried in turn. Importing from
  ~/.ssh/config offers the agent a host names with IdentityAgent, and reuses
  an agent identity already made for it.

### Fixed
- **The sidebar slides open with less stutter.** On macOS 26 the sidebar
  floats over the page, and every step of its slide moved the page's margin,
  so the whole page was laid out again at each frame. The page now moves
  with the sidebar without being laid out, and is laid out once, after an
  opening slide stops or as a closing one starts.

## [0.2.8] - 2026-10-19

### Fixed
- **The sidebar slides open smoothly.** Showing the sidebar stuttered, worst
  on Home and with terminals open: every step of the slide redrew Home's
  server cards, laid out again every terminal, Files, Monitor and Settings
  page kept behind the one in view, and told each terminal's server its new
  size. Pages out of sight now keep their size until they are shown, Home
  redraws only when its inspector would change width, and a terminal's server
  hears its size once it has settled.

## [0.2.7] - 2026-10-19

### Changed
- **Closing the window keeps Tamio running in the background.** Clicking the
  close button or pressing ⌘W closes the window without quitting the app, so
  the MCP server, port forwards and open terminals stay connected and the
  window opens again at once from the Dock, the menu bar or ⌘0. While the
  window is closed, background status polling pauses (waking on demand when an
  agent asks for metrics, if Live server status is on), Files and Monitor
  pages close, and App Nap is allowed whenever no SSH session is active. Quit
  (⌘Q) still quits the app.

## [0.2.6] - 2026-10-19

### Added
- **A server can sign in with no password or key.** Credentials in New or
  Edit Server has a third choice, None, for a server that trusts the
  connection itself, as Tailscale SSH does: Tamio asks to sign in with
  nothing, and the server lets the user in. Terminals, Files, live status,
  snippets, port forwards, the menu bar and agents all sign in that way; a
  server that wants credentials after all says which. Agents set it with
  `"auth": "none"` in add_host or update_host; list_hosts shows `none` for
  such a server and `missing` for one Tamio has nothing to sign in with.
- **Import servers from OpenSSH configuration.** Servers › Import previews
  concrete Host aliases with their effective address, user, port, credentials,
  source location and compatibility warnings. Includes and defaults are
  resolved by the Mac's OpenSSH using a frozen, inspected configuration,
  with the Mac's own /etc/ssh/ssh_config applied after yours, as ssh does;
  Match exec requires explicit trust, and resolution has cancellation, time
  and output limits. Private keys are copied only with permission, shared
  keys are reused, and existing servers are skipped unless explicitly updated.
  ProxyCommand and supported single- or multi-hop ProxyJump connections are
  preserved, with a warning about local configuration and key dependencies.
  The source files and OpenSSH known_hosts are never modified or imported;
  unsupported authentication, forwarding and trust policies are disclosed
  before confirmation. Dynamic Includes that cannot be inspected safely are
  rejected. Available in English and Simplified Chinese.
- **Tamio speaks Simplified Chinese.** On a Mac set to Simplified Chinese,
  its pages, sheets, settings and the terminal's configuration catalog are in
  Chinese; server names, addresses, paths and commands stay as they are. What
  agents are told through MCP stays in English, so they read it the same on
  every Mac.

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
