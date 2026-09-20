# Live validation evidence - fm/fm-reconcile-upstream-2026-09-18

Change under test: `d5967e12..1e2e5e5` - merge of 47 upstream `kunchenguid/firstmate`
commits into this fork (`8fa641e`), plus five post-merge review-round fixes to the
contribution path and the live codex composer guard.

Everything below was driven against the real firstmate CLIs (`bin/fm-*.sh`) on this
macOS host, in isolated temporary homes.

| File | What it shows |
|---|---|
| `contributions-cli-transcript.log` | Hand-driven CLI transcript: a captain backlog with one good row and three unnameable/prose-hinted rows, through `fm-contributions.sh poll`, `arm --if-owned` and `fm-bearings-snapshot.sh --json`. Shows **0** forge reads spent on the URL owned only by an unnameable id, no durable directory created, coverage `complete/proven_clear = true`, the prose repo hint falling back to the no-project container, and a trailing-slash data root writing records while a symlinked root is still refused. |
| `drive-contributions.sh`, `gh-fixture.sh` | The driver and offline forge stub used to produce the transcript above. |
| `bash32-churn-regression.log` | The `e213343c` bash 3.2 fix, driven under this host's real `/bin/bash 3.2.57` with the CI lane's PATH. Negative control first (guard reverted -> `missing_keys[@]: unbound variable`, watcher cycle dies), then the merged code passing. |
| `macos-stock-bash32-snapshot-lane.log` | The macOS stock-bash CI lane's snapshot consumers (`fm-fleet-snapshot-view`, `fm-bearings-snapshot`) run under real `/bin/bash 3.2.57` with `tasks-axi 0.2.5`. |
| `upstream-dead-agent-report-once.log` | `9bc051ff` - a dead/missing endpoint reports once, re-arms when it comes back, and live/unproven endpoints still escalate. |
| `upstream-latest-status-event.log` | `334fa122` - latest-status-event folding: decision keys, wake-drain cursor, inactive reconcile, send key resolution, captain-hold lifecycle. |
| `upstream-crew-state-pr-and-status.log` | `7111081c` - `terminal passed` runs report verified PR/MR state (open, merged, GitLab, unreadable identity) instead of claiming merged. |
| `upstream-pr-merge-poll-remount.log` | `baede47d` - merge polls survive volume remounts; validated merged polls notify once and retire. |
| `upstream-watch-triage-partial.log` | Watcher triage suite, stopped at 85/244 cases with 0 failures (each case runs a real watcher at live poll intervals). The cases owned by `9bc051ff` and `e213343c` were run individually to completion - see the two rows above/below. |
| `fork-local-behaviour-merge-conflicts.log`, `-2.log`, `-3.log` | The suites owning every file the merge had to reconcile from both sides (composer, brief, control relaunch, fleet snapshot, gotmp, task delivery, spawn dispatch profile, zellij backend, teardown, teardown endpoint safety, backlog handoff, backlog atomicity, public followup/promote, herdr backend smoke). |
| `nameable-owner-rule-differential.log` | Adversarial differential proving the jq `nameable_task` rule the coverage projection now shares with poll accepts an id exactly when both shell predicates (`fm_pr_task_id_valid`, `fm_task_data_valid_id`) do - across `tasks`, `-dash`, `.hidden`, `a b`, `a/b`, `../escape`, non-ASCII and a shell-injection string. |
| `live-codex-idle-composer-guard.log` | `d82afe3` starfield guard. The negative control shows the pre-fix line calling `_fm_composer_row_is_braille_furniture`, removed by upstream's rename -> `command not found`. The guard as a whole cannot reach its verdict on this host: codex parks on a folder-trust prompt for the ephemeral gate worktree path (see below). |

## Not drivable here

`tests/fm-composer-codex-idle-live-e2e.test.sh` launches the installed `codex`
in an isolated tmux server and requires an idle composer. On this host codex
0.155.0 shows an update-available modal (dismissed by the guard's Escape) and
then a **folder-trust prompt** for
`/Users/johnbalke/.no-mistakes/worktrees/6b5c7015552c/01M2ZFHFZER4D9XE67D807JABW`,
which `~/.codex/config.toml` has never trusted (it trusts
`/Users/johnbalke/dev/john/firstmate`). Trust is recorded only in that
user-level file, and `codex -c 'projects."<path>".trust_level="trusted"'` does
not override it. Writing it is a global user-config change this run's workspace
boundary forbids.

To enable: run `codex` once in this worktree (or in the checkout the guard will
run from) and answer *"1. Yes, continue"*, then re-run the guard. In CI the
guard's `fm_live_gate default-on FM_COMPOSER_CODEX_IDLE_LIVE codex tmux` skips
because codex is not installed, so this is a local-host condition only.
