# Scripting and agents

This page describes how to drive LazySpace from scripts and AI agents. For the list of commands, run `lazyspace help`.

The running app accepts CLI requests from processes running as the same macOS user. The CLI automatically reads a per-launch credential from the user's LazySpace application support directory; scripts need no prompt or extra argument. LazySpace refuses CLI control if the directory is writable by another user or its `control-credential` file is readable by another user. ACL entries that grant access are also refused; deny-only ACLs are allowed. Restarting the app rotates the credential. A different user cannot use the control port through the CLI.

Run the CLI as the logged-in user, without `sudo`. If `LAZYSPACE_SUPPORT` is set, the app and CLI must use the same value so they find the same credential. A sandboxed caller must also be allowed to read that directory. When the instance lock is held but CLI communication fails, JSON output uses `control-unavailable` (exit 2); `connection-unavailable` means the CLI could not confirm a running app. Check the folder's ownership and permissions if communication fails while the app is open.

## Arguments are checked strictly

The CLI rejects unknown flags, extra arguments, duplicate options, and state commands without `on` or `off` before it sends anything to the app.

## Acting on a specific window

Get window IDs and process IDs from `list-windows --json`, and the current Space from `currentSpaceID` in `status --json`. Then name the target explicitly instead of relying on focus:

```bash
lazyspace resize width -0.1 --window-id 123 --expect-space-id 884 --expect-pid 456 --json
lazyspace zoom on --window-id 123 --expect-space-id 884 --json
lazyspace focus --window-id 123 --expect-space-id 884 --json
lazyspace undo --expect-space-id 884 --json
```

The IDs above are examples. Use values you have just read.

- `--window-id` requires `--expect-space-id`. `--expect-pid` also guards against the window belonging to a different process.
- The target's process and app are recorded when the request is accepted and checked again when it runs.
- Read window IDs and process IDs again after the target app restarts. Restarting LazySpace makes receipt tokens unusable (see below).
- With an explicit target, LazySpace never falls back to the focused window.
- `move-to-space` also requires the target window to be in front.
- `move-to-space` without `--follow` always stays on the current Space. The setting that makes the shortcuts and the menu follow a moved window does not change the command line.
- A change of Space, a pause, or user input interrupts an accepted operation.
- A request that arrives while another operation is running returns `busy`. It is not merged into keyboard work.

`space N` and `move-to-space N` use the display with the focused window. To name a desktop of another display, add `--display N`, where N is the display's position in `list-spaces`. In `list-spaces --json`, a Space can include `display` (the macOS display identifier), `displayName`, and `displayIndex`; values that cannot be read are left out. `--display` needs a desktop number and cannot be combined with `next`, `prev`, or `back`. Display positions can change when a display is connected or disconnected, so read them again before each request.

Window targets work with `focus`, `swap`, `move`, `join`, `resize`, `float`, `zoom`, `close`, `fullscreen`, `minimize`, `toggle-split`, `accordion`, and `move-to-space`. `--expect-space-id` also works with `arrange`, `integrate`, `balance`, `undo`, and `space`.

A few commands have their own conditions:

- `minimize off` requires an explicit window ID.
- `zoom on` and `zoom off` do not raise the window or take focus.
- `fullscreen` and `minimize` set the state through Accessibility as an absolute value. An app that only offers a toggle button can refuse.
- Success is decided by reading the state back. An animation or a refusal by the app can produce a partial result.

## Reading JSON results

- JSON output has `schemaVersion` 2, and every error has a `code`.
- The code `finished` means the operation ended. Read `ok` and `result.outcome` to learn whether it succeeded.
- `operationID` and `result.id` identify the operation. `requestID` identifies the receipt. One is never substituted for the other.
- Messages meant for people follow the app's display language. Read the structured fields instead.
- Window listings cover the current Space only, and `--all` is rejected. Window titles are not included in JSON or in logs.

Exit codes: only a completed, successful operation exits 0. A `result` query for a receipt that is pending or was never sent exits 1.

### Timeline

For `space` and `move-to-space`, a finished operation has `result.timeline`. It lists what happened, in order, in milliseconds with one decimal, on a monotonic clock that starts when LazySpace accepted the request. The events are `accepted`, `queued` (the operation started), `prepared`, `mainKeyPosted` and `arrivalObserved` (with `step` for each stepping key and `attempt` for each shortcut press), `activationConfirmed`, and `published`.

- Other commands have an empty timeline.
- An operation that was accepted and then stopped keeps the events up to that point, and querying the receipt returns the same list.
- A request refused on arrival (for example `busy`, `same-space`, or a usage error) starts no operation and has no timeline.

With `--json`, the CLI adds `receivedAt`: the milliseconds, on the CLI's own clock, between the acceptance reply and the finished result. The two clocks differ, so do not add the values together. The CLI checks for the result every 20 ms for the first 2 seconds, every 100 ms until 10 seconds, and every 250 ms after that.

## Receipts: running a change exactly once

`arrange`, `integrate`, and the window and Space edits change something. For these, the CLI reserves a receipt and sends the request once. `pause`, `resume`, `settings`, `reload`, `mode`, `login-item`, `status`, `list-windows`, `list-spaces`, and `wait-settled` do not use receipts.

- Sending the same receipt with the same request returns the original outcome and does not start a second operation. This also holds when the first reply was lost.
- Changing the command, edit, window, Space, process, or desired state on a receipt returns `request-conflict` and does nothing.
- `busy` and every other refusal stay attached to that receipt, even after the app becomes idle. A new attempt needs a new token from `request-token`.
- Reserving a token does not select a window and does not authorize later work. `request-token` is safe to repeat, because an unused reservation changes nothing.
- A reservation that is not sent expires after 60 seconds. At most 64 reservations and running changes are held, and running changes are never evicted.
- The latest 32 finished receipts, refusals included, are kept separately from the latest 32 ordinary operation results. Reading a receipt does not keep it longer. Repeating a receipt that has expired or been evicted returns `request-expired` and does not run again.

Use `--request-id` to supply a token you reserved yourself. That is how you can recover if your process exits before the CLI prints the token. LazySpace does not write tokens to the configuration file.

Commands that set a state (`float on`, `zoom off`, and the like) can be repeated with a new receipt without undoing anything. Relative changes are different: for `resize`, `move`, `swap`, `undo`, and Space movement, query the original receipt instead of sending the change a second time.

## When something goes wrong

- A reply is treated as `protocol-error` if it omits the request the CLI is tracking, names a different one, changes an operation ID already seen, or uses an unsupported schema or an impossible state. The CLI does not treat such a reply as success and does not send the change again.
- A reservation that claims success without a request ID is rejected, and no change is sent.
- Restarting LazySpace starts a new session. An old token then returns `session-mismatch`. The earlier change may already have happened, and its outcome is no longer available.

After a lost reply or a restart, do not make up a replacement token. Query the same token. Or look at the desktop, and reserve a new token only if you intend to make a new change.

## Waiting for the desktop to settle

`idle` in `status` only tells you that the queue and mouse handling are quiet. To wait for the Space itself, use `wait-settled`.

`wait-settled` takes fresh observations on the operation queue and checks for arrival handling, input, and deferred automatic work. Each call starts its own waiting interval. It finishes when the windows of the current Space have stayed unchanged for at least one second, or for the configured `quiet-interval` if that is longer. Its `settlement` field includes the observation time, the Space, the stable interval, and anything that blocked it.

A finished `wait-settled` means the Space was observed to be stable. It does not lock the desktop and says nothing about what apps will do next.
