---
name: tamio
description: Work on the user's SSH servers through Tamio's MCP server — list hosts and their live load, run commands on one or many servers (the user approves, Tamio signs in with its own saved keys), add or change servers, SSH keys, snippets and port forwards, and keep each server's agent activity log. Use whenever a task touches the user's servers, fleets, deploys, updates, or "my hosts".
---

# Tamio

Tamio is the user's SSH client for macOS. Its MCP server (`tamio`) knows every
server the user saved: address, port, user, group, tags, how it signs in, any
proxy command it connects through, and its live CPU, memory, disk, load and
traffic.

## Set up (once)

Tamio must be running with **Settings › MCP › MCP server** on (it is by default).

- Claude Code: `claude mcp add tamio -- /Applications/Tamio.app/Contents/Resources/tamio-mcp`
- Codex (`~/.codex/config.toml`):
  ```toml
  [mcp_servers.tamio]
  command = "/Applications/Tamio.app/Contents/Resources/tamio-mcp"
  ```
- Any other MCP client: a stdio server whose command is
  `/Applications/Tamio.app/Contents/Resources/tamio-mcp`.

## Rules

1. **Read the server's history first.** Before working on a server, call
   `get_activity` with its name: earlier agents, on any of the user's Macs, may
   have changed it.
2. **Run through Tamio.** Prefer `run_command` (or `run_snippet`) over your own
   `ssh`: Tamio signs in with its saved key or password, checks the host key,
   asks the user, records the run in the server's activity, and returns each
   server's exit code and output. Target many servers at once with
   `{"targets": {"group": "Production"}}`, `{"tag": "web"}` or `{"all": true}`.
3. **Name the task.** Give every call that changes something a `task`: a short
   name for the goal it serves, such as `"Install nginx"`. Use the same `task`
   for every step toward that goal (adding the repository, `apt update`, the
   install, its config): Tamio keeps them as one entry in the server's history,
   titled with the task, with each step and its result under it. The next agent
   then sees what was done, not a list of commands.
4. **Report what you do by other means.** If you change a server with your own
   ssh, scp, rsync or a deploy tool, call `log_activity` for it right after,
   with a one-line `summary`, what changed in `details`, and the `commands` you
   ran, and the same `task`. Never put secrets in it.
5. **Secrets only go in.** Tamio never returns passwords, private keys or
   passphrases. To give a server a key, call `add_identity` with
   `generate: true`; it returns the public key — install it in the server's
   `~/.ssh/authorized_keys` (for example with `run_command` on a server you can
   already reach), then `update_host` with `identity`.
6. **Every change is approved by the user.** `run_*`, `add_*`, `update_*`,
   `remove_*`, `start_*`/`stop_*` wait for them. Say what you are about to do
   and why before calling one; if they decline, ask rather than retry.
7. Use `sudo: true` for root commands: it runs `sudo -n`, which fails instead of
   waiting for a password; say so if a server needs one.

## Tools

| Tool | What it does |
|---|---|
| `list_hosts` | Servers (filter by `query`, `group`, `tag`) |
| `get_host` | One server, with live status |
| `get_metrics` | Live CPU, memory, disk, load, network, traffic, OS |
| `export_ssh_config` | `Host` blocks, no keys |
| `run_command` / `run_snippet` | Run on servers; exit code and output per server |
| `add_host` / `update_host` / `remove_host` | Manage servers (`password` is write-only; `proxy_command` sets an `ssh_config` `ProxyCommand`) |
| `list_identities` / `add_identity` / `remove_identity` | SSH keys; public keys only |
| `list_snippets` / `add_snippet` / `update_snippet` / `remove_snippet` | Saved commands |
| `list_port_forwards` / `add_port_forward` / `start_port_forward` / `stop_port_forward` / `remove_port_forward` | Tunnels through a server |
| `get_activity` | What agents did on a server, newest first, from every Mac; a task's steps are under it |
| `log_activity` | Record what you did on servers by other means |

## Example: update every production server

1. `get_activity {"host": "…"}` for a few of them, to see recent changes.
2. `run_command {"targets": {"group": "Production"}, "command": "apt-get update && apt-get -y upgrade", "sudo": true, "timeout": 900, "task": "Upgrade packages"}`
3. For servers where `/var/run/reboot-required` exists:
   `run_command {"targets": {"hosts": [...]}, "command": "test -f /var/run/reboot-required && echo REBOOT", "task": "Upgrade packages"}`,
   then ask the user before rebooting.

## Example: add a server behind Cloudflare Access or another ProxyCommand

Give `add_host` or `update_host` a `proxy_command` with `%h` for the server's
`address` and `%p` for its `port`, the same as `ProxyCommand` in `~/.ssh/config`:

- Cloudflare Access tunnel:
  `add_host {"name": "edge-01", "address": "ssh.example.com", "username": "root", "group": "Cloudflare", "identity": "<key id or name>", "proxy_command": "cloudflared access ssh --hostname %h"}`
- Connect directly again:
  `update_host {"host": "edge-01", "proxy_command": ""}`
