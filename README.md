# zellij-reaper

A small, paranoid systemd-user timer that cleans up stale [zellij](https://zellij.dev)
sessions on a Linux box (or WSL2 with `systemd=true`).

Targets two kinds of session you usually want gone:

- **EXITED** — the server process is dead, but `zellij ls` still lists it
  because the resurrection layout is on disk.
- **IDLE** — the server is alive, nobody is attached, and every pane is sitting
  at a bare shell prompt with no foreground command running.

Surviving sessions are also given more meaningful names: if the current name
is still the zellij default (e.g. `marvellous-ocelot`) or already in our own
`<base>_MMDD-HHMM` format, the reaper renames it based on the first pane's
title (or, failing that, the launch directory) and appends the session's
last-activity timestamp as a `_MMDD-HHMM` suffix. For a session whose pane
title is `vim foo.txt` and was last touched at 14:31 on May 12, the rename
target is `vim-foo-txt_0512-1431`; the suffix refreshes on every pass so the
name reflects when you were last in there. Collisions get a `-2`, `-3`, ...
tail. Disable with `AUTO_RENAME=0`.

Sessions that meet **any** of the following are never touched:

- a client is currently attached (`session-metadata.kdl::connected_clients > 0`,
  or a live socket peer on `ss -xp`);
- any pane has a running foreground command (detected by looking at the shell's
  child processes);
- the session layout was built with a `claude` command (or a `claude` process
  is currently running under it) — Claude Code sessions are protected as a
  special case **while RUNNING**; once they go EXITED ("attach to resurrect")
  the protection lifts and the normal age threshold decides;
- the session's last-activity mtime is younger than the configured threshold
  (`MAX_AGE_HOURS`, default `1h`);
- a user-supplied `PROTECT_REGEX` matches the session name.

The reaper fails closed: any uncertainty (e.g. `ss` missing, metadata
unreadable) results in a `SKIP`, never a deletion.


## Install

```sh
git clone https://github.com/jingukang-bricksum/zellij-reaper.git
cd zellij-reaper
./install.sh
```

The installer:

1. Verifies `systemctl --user`, `bash`, `awk`, `grep`, `stat`, `pgrep`, `ps`.
2. Warns (but does not abort) if `zellij` or `ss` is missing.
3. Drops `zellij-reaper.sh` into `~/.local/bin/` and the two units into
   `~/.config/systemd/user/`.
4. Runs `systemctl --user daemon-reload` and `enable --now` on the timer.
5. Enables linger so the timer keeps ticking when no shell is logged in.

Re-run any time to upgrade; the install is idempotent.


## Update

```sh
cd zellij-reaper
git pull
./install.sh
```

The installer **overwrites** `~/.local/bin/zellij-reaper.sh` and the two
systemd unit files unconditionally. If you have hand-edited the service file
to change `MAX_AGE_HOURS` or `DRY_RUN`, back it up first or note your values:

```sh
cp ~/.config/systemd/user/zellij-reaper.service{,.bak}
git pull && ./install.sh
# then re-apply your env values to the new service file and:
systemctl --user daemon-reload
```


## Configure

Edit `~/.config/systemd/user/zellij-reaper.service`:

```ini
Environment=DRY_RUN=0          # set to 1 to log decisions without deleting
Environment=MAX_AGE_HOURS=1    # threshold; or use MAX_AGE_DAYS instead
# Environment=AUTO_RENAME=0            # optional, disable auto-renaming
# Environment=PROTECT_REGEX=^keep-     # optional, names matching are skipped
```

Then `systemctl --user daemon-reload`.

The timer fires on a 1-hour interval (`OnUnitActiveSec=1h`, `AccuracySec=5min`,
`Persistent=true`) and 10 minutes after boot. Adjust in
`~/.config/systemd/user/zellij-reaper.timer` if needed.


## Run on demand

```sh
zellij-reap run         # one normal pass (uses the timer's threshold)
zellij-reap force-run   # bypass the age check; reap any idle/exited session
                        # that passes every other safety guard
zellij-reap --help
```

`force-run` is the "I know what I'm doing, drop everything that isn't actively
in use" button. It still refuses to touch:

- sessions with a connected client,
- sessions with any foreground command running in any pane,
- sessions whose layout was created with `command="claude"`,
- sessions whose name matches `PROTECT_REGEX`.

If `~/.local/bin` is not on your `PATH`, run `./reap.sh run` from the repo
directory instead.


## Inspect

```sh
systemctl --user list-timers zellij-reaper.timer    # next scheduled fire
tail -f ~/.cache/zellij-reaper.log                  # decisions, with pane titles
```

A typical log line:

```
2026-05-12 09:21:56  marvellous-ocelot [RUNNING] panes={vim foo.txt|tail -f app.log} :: SKIP client attached (metadata:connected_clients=1)
```


## Uninstall

```sh
./install.sh --uninstall
```

Removes the binary and the two units. The log file is left alone in
`~/.cache/zellij-reaper.log`.


## How it decides — in short

For each session listed by `zellij ls`:

```
PROTECT_REGEX matches?               -> SKIP
no session_info dir on disk?         -> SKIP (transient)
layout contains `command="claude"`
  or descendant proc is `claude`?    -> SKIP (Claude Code protected)
EXITED?
  age >= threshold?                  -> REAP
  else                               -> SKIP
RUNNING:
  socket missing?                    -> SKIP
  server PID not found?              -> SKIP
  client attached (metadata or ss)?  -> SKIP
  attach check uncertain?            -> SKIP
  any pane shell has a child proc?   -> SKIP (busy)
  age >= threshold?                  -> REAP
  else                               -> SKIP
```


## Caveats

- The "last activity" signal is the mtime of files under
  `~/.cache/zellij/contract_version_1/session_info/<name>/`, which zellij
  updates on its own schedule (not continuously). A session you detached from
  five minutes ago may have an mtime that is already 15 minutes old. Pick
  `MAX_AGE_HOURS` accordingly.
- A background job started with `disown` (or `nohup`) reparents to `init` and
  is no longer a child of its pane's shell. That pane will look idle to the
  reaper. This is intentional — such jobs survive the reaper deletion too.
- Tested against zellij `0.44.x`. The schema of `session-metadata.kdl` /
  `session-layout.kdl` is not a stable API; future zellij releases may rename
  fields. The reaper degrades gracefully (it just stops finding clients /
  claude markers), but verify after a major upgrade.


## License

MIT — see `LICENSE`.
