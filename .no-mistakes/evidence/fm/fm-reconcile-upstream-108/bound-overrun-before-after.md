# tasks-axi watchdog group-kill: measured before/after

Host: darwin, **no GNU `timeout`/`gtimeout` on PATH**, so `fm_tasks_axi` takes the
perl watchdog branch in `bin/fm-backlog-transition-lib.sh`. CI (ubuntu) takes the
GNU `timeout` branch and never reaches this code.

Scenario driven end to end by
`tests/fm-backlog-atomicity.test.sh::test_deferred_signal_verification_outlives_an_unresponsive_tasks_axi`:
a real `bin/fm-spawn.sh` is interrupted after launch delivery, its read-back
`tasks-axi start` never answers, `FM_TASKS_AXI_TIMEOUT=3`, outer bound 30s.

| lib version | inner bound | spawn exit | wall clock | case |
|---|---|---|---|---|
| `37bfb08` (plain `kill "TERM", $pid`) | 3s | 124 (killed by the 30s outer bound) | **31s** | not ok |
| `2fe85ad` (`setpgrp` + `kill "TERM", -$pid`) | 3s | 143 (the spawn's own deferred signal) | **18s** | ok |

Identical fixture, identical host, identical invocation; the only difference is
`bin/fm-backlog-transition-lib.sh` swapped between the two commits.

Both runs print the same user-visible wording:

```
error: spawn of atomic-dispatch-signal-hang-b5 was interrupted after launch delivery began;
preservation could not be verified: its backlog item reads queued no no, and moving it to
In flight failed (tasks-axi start atomic-dispatch-signal-hang-b5 did not finish within 3s);
close out its paired task record and backlog item by hand
```

The difference is whether the caller ever gets to return it. Without the
group-kill, the hung `tasks-axi`'s grandchild survives the TERM/KILL aimed at
its parent and keeps the caller's captured stdout open, so the command
substitution blocks while the per-task meta lock is still held - the exact
lock-held-forever hazard the bound exists to prevent.

Full suite at HEAD: `tests/fm-backlog-atomicity.test.sh` 101 ok, 0 not ok, exit 0.
