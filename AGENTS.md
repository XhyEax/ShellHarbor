# ShellHarbor Agent Guide

## Scope

This file applies to the entire repository.

ShellHarbor is a native macOS 14+ SwiftUI application for interactive SSH,
Mosh, SCP, remote inspection, and file management. It also ships the `shcli`
command-line client. Preserve the native AppKit/SwiftUI implementation; do not
replace application features with a web view or a non-interactive command
runner.

## Repository Layout

- `Sources/ShellHarbor/`: macOS application.
- `Sources/ShellHarborCLI/`: thin `shcli` executable entry point.
- `Sources/ShellHarborCLIKit/`: shared CLI profile resolution, password
  decryption, and SSH launch support.
- `Tests/ShellHarborTests/`: application and CLI tests.
- `Resources/`: app metadata and packaged resources.
- `Tools/GenerateIcon.swift`: app icon generator.
- `scripts/package_app.sh`: release build, `.app` assembly, CLI copy, icon
  generation, and ad-hoc signing.
- `dist/`: generated output. Do not edit or commit it.

## Build and Verification

Run commands from the repository root.

```bash
swift build
swift test
git diff --check
```

For changes affecting the application bundle, resources, CLI packaging, app
startup, or visible UI behavior, also run:

```bash
./scripts/package_app.sh
codesign --verify --deep --strict dist/ShellHarbor.app
codesign --verify --strict dist/shcli
```

When a UI fix needs a manual check, launch the newly packaged build rather than
an older installed copy:

```bash
pkill -x ShellHarbor || true
open -n "$PWD/dist/ShellHarbor.app"
```

Do not commit or push unless the user explicitly requests it. Preserve
unrelated changes in a dirty worktree.

## Architecture and Ownership

- `ShellHarborApp` owns the application commands and injects the shared
  `AppState`.
- `AppState` is `@MainActor` and coordinates persisted Remotes, active
  workspaces, transfer processes, inspection tasks, restoration, and global
  settings.
- Each open tab must have its own `SessionWorkspace` and `TerminalController`.
  Never share a mutable terminal, file selection, command history, transfer
  queue, or remote path between tabs.
- A Remote is a persisted connection profile. A Session is a runtime workspace.
  One Remote may have multiple Sessions. Switching a Remote or tab must not
  reconnect an already open Session.
- `SSHCommandBuilder` is the single place for SSH, SCP, Mosh, proxy, jump-host,
  host-key, authentication, and shell quoting behavior. Extend it instead of
  assembling connection commands in views.
- `CommandRunner` handles non-interactive subprocesses. Interactive terminal
  connections must use the PTY-backed `TerminalController` and SwiftTerm.
- `RemoteFileService` owns remote path/list/stat/rename/delete operations.
  Remote shell input must always be quoted with the existing shell-quote
  helpers.
- `SessionStore`, `SessionRestorationStore`, and `InspectionStore` own their
  respective persistence formats. Make decoding backward-compatible when
  adding fields.
- Views should express presentation and user intent. Put connection, transfer,
  persistence, and filesystem behavior in the state or service layers.

## Product Invariants

### Terminal and Sessions

- SSH is a true interactive PTY session, not “connect, then run one command.”
- Keep ANSI/xterm colors, cursor addressing, alternate-screen applications,
  mouse input, resize propagation, and the configured SwiftTerm scrollback
  intact.
- Do not show raw ANSI control characters or expose the generated SSH command
  or password in the UI.
- `Command-N` and `Command-T` create a Session; `Command-W` closes the current
  Session. `Command-K` clears the local terminal buffer while preserving the
  current editable line. `Command-F` searches the terminal.
- Restorable Sessions retain the terminal buffer, pending input, terminal
  directory, selected view, and connection intent unless the user explicitly
  closes the Session.
- Session tab rename changes only the numeric/custom suffix; the Remote name
  remains authoritative and updates live when the Remote is renamed.

### Remote Profiles and Connectivity

- An empty host resolves to `127.0.0.1`; do not introduce a DNS dependency for
  the default local target.
- Prefer and respect applicable `~/.ssh/config` behavior. New hosts use the
  safe first-connect policy already implemented; changed host keys must still
  be treated carefully.
- Proxy and jump-host settings affect SSH/SCP and the Mosh bootstrap stage.
- “Target Mosh” means SSH may bootstrap through the jump host, followed by UDP
  directly to the target.
- “Mosh on jump -> SSH target” means UDP terminates on the jump host, then an
  interactive `ssh -tt` enters the target. Keep jump Mosh and target
  `mosh-server` paths separate.
- Do not force `/bin/sh` as the remote login shell. Let the remote account
  choose its shell unless a narrowly scoped bootstrap command requires one.
- Refresh the left-side connectivity indicator immediately when a connection
  or reconnect starts. Offline Remotes use the neutral gray state.

### Secrets

- Never print passwords, include them in display commands, command-line
  arguments, logs, environment diagnostics, tests, or temporary files.
- Stored passwords use ShellHarbor's local encrypted configuration and local
  RSA key material. Do not add Keychain persistence.
- `shcli ls` must not decrypt passwords. `shcli c` may decrypt only the selected
  target and required jump profile, then pass secrets through anonymous file
  descriptors/pipes.
- Keep target and jump passwords on separate descriptors.
- Redact sensitive command representations and error output before presenting
  them to users.

### Files and Transfers

- Local and remote panes are independent and remember paths and sort settings
  per Remote.
- The local default directory is `~/Downloads`.
- Path fields accept directories and file paths. A file path navigates to its
  parent, selects the file, and scrolls it into view. Preserve `~` expansion and
  path completion.
- Preserve Finder drops, internal local/remote drag payloads, multi-selection,
  folder upload, and full-pane drop targets. A remote file dragged to a terminal
  inserts its safely quoted full path.
- Local file double-click opens locally; remote directories navigate. Supported
  small remote text files may download and open with the macOS default app.
- Name collisions generate `name (1).ext`. Folder sorting follows the selected
  macOS-style column ordering; do not force folders to the top.
- Transfers support pause and stop. Recursive tasks must calculate real byte
  totals without delaying the start of SCP, update progress while running, and
  show transferred bytes plus elapsed time when finished.
- Local delete moves items to Trash without an extra confirmation. Remote
  permanent delete remains explicit and carefully scoped.
- Remote listing/parsing must tolerate long output, spaces, empty directories,
  shell glob behavior, BSD userlands, and non-zero SSH exits that still contain
  parseable diagnostic output.

### Persistence and Inspection

- The selected view, local path, remote path, and both sort configurations are
  per Remote and survive relaunch.
- File lists refresh every 15 seconds only while their view is active; avoid
  overlapping refreshes and stale async results.
- Inspection configuration and logs are per Remote. Keep inspection work off
  the main thread and publish state changes on `@MainActor`.
- Adding persisted fields requires defaults for older configuration and
  restoration files.

### CLI and App Bundle

- The executable is named `shcli`.
- Supported short commands include `shcli ls` and `shcli c <name|index|UUID>`;
  retain long aliases unless removal is explicitly requested.
- The Homebrew link is `/opt/homebrew/bin/shcli`, is enabled by default, and
  must follow the most recently launched `.app` path. Only replace or remove a
  link that ShellHarbor manages.
- If the app is moved, launching it from the new location must repair the link.

## Swift Conventions

- Use Swift 6 concurrency rules. UI-observable mutation belongs on
  `@MainActor`; expensive filesystem traversal and blocking process work should
  run off the main actor.
- Prefer structured concurrency and cancellation-aware loops. Check
  `Task.isCancelled` in refresh, inspection, and recursive filesystem work.
- Keep subprocess lifecycle cleanup deterministic. A cancelled or stopped task
  must not later overwrite its state as completed.
- Use Foundation path APIs for local paths and the existing POSIX remote-path
  helpers for remote paths; do not treat a remote path as a local `URL`.
- Avoid force unwraps for user or persisted input.
- Match the surrounding SwiftUI style and SF Symbols. The application defaults
  to its night theme.
- Add focused regression tests for parsing, quoting, persistence migration,
  command construction, transfer accounting, and pure model behavior.

## Change Checklist

Before handing off a change:

1. Confirm the behavior belongs to the selected Remote and Session, not global
   fallback state.
2. Check local, direct SSH, jump-host, and password-auth implications where
   relevant.
3. Check cancellation and stale async results.
4. Run `swift test` and `git diff --check`.
5. Package, verify signatures, and relaunch for visible app changes.
6. Report what changed, tests run, whether the app was relaunched, and whether
   changes remain uncommitted.
