# Scripting and agents

This page describes how to drive LazySpace from scripts and AI agents. For the list of commands, run `lazyspace help`.

The running app accepts CLI requests from processes running as the same macOS user. The CLI automatically reads a per-launch credential from the user's LazySpace application support directory; scripts need no prompt or extra argument. LazySpace refuses CLI control if the directory is writable by another user or its `control-credential` file is readable by another user. ACL entries that grant access are also refused; deny-only ACLs are allowed. Restarting the app rotates the credential. A different user cannot use the control port through the CLI.

Run the CLI as the logged-in user, without `sudo`. If `LAZYSPACE_SUPPORT` is set, the app and CLI must use the same value so they find the same credential. When the instance lock is held but CLI communication fails, JSON output uses `control-unavailable` (exit 2); `connection-unavailable` means the CLI could not confirm a running app. Check the folder's ownership and permissions if communication fails while the app is open.

A sandboxed caller needs two permissions: to read that directory, and to look up LazySpace's Mach service, whose name begins with `jp.lazyspace.control.`. Without read access, the CLI can't tell that LazySpace is running, so it reports `connection-unavailable`. A sandbox that allows only a fixed list of Mach services blocks the lookup, and the CLI reports `control-unavailable`. In that case, run the command outside the sandbox.

## Finding the command

Homebrew installs `lazyspace`. Without Homebrew, link it into your `PATH` as the [guide](guide.md#the-lazyspace-command-without-homebrew) shows. When the command is not on `PATH`, call it inside the app: `/Applications/LazySpace.app/Contents/Resources/bin/lazyspace`.

## Arguments are checked strictly

The CLI rejects unknown flags, extra arguments, duplicate options, and state commands without `on` or `off` before it sends anything to the app.

## Acting on a specific window

Get window IDs and process IDs from `list-windows --json` (`inspection.targets[].id` and `.pid`), and the current Space from `currentSpaceID` in `status --json`. The `ID` column of `lazyspace list-windows` shows the same numbers. Then name the target explicitly instead of relying on focus:

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

- JSON output has `schemaVersion` 3, and every error has a `code` (see [Codes](#codes)).
- The code `finished` means the operation ended. Read `ok` and `result.outcome` to learn whether it succeeded.
- `operationID` and `result.id` identify the operation. `requestID` identifies the receipt. One is never substituted for the other.
- Messages meant for people follow the app's display language. Read the structured fields instead.
- Window listings cover the current Space only, and `--all` is rejected. Window titles are not included in JSON or in logs.

### Values

- Window IDs and Space IDs are integers: `"id": 123` is the window that `--window-id 123` names. This holds for `status` (`focusedWindow`, `zoomed`, `floating`, `waiting`), `list-windows`, `list-spaces` (`windowIDs`, `unknown`), and results. Space IDs are unsigned 64-bit integers; parse them without going through floating point (JavaScript's `JSON.parse` loses digits above 2^53).
- Receipt tokens (`requestID`) and operation IDs (`operationID`, `result.id`) are strings.
- Rectangles (`frame`, `workArea`, and a result target's `before`, `planned`, and `after`) are objects with `x`, `y`, `width`, and `height`, in points, in the coordinates macOS uses for windows: the origin is the top-left corner of the main display and y grows downward, so a window on a display to the left of or above it has negative coordinates.
- `result.outcome` is a string (see [Outcomes](#outcomes)).
- In a settlement, `stableFor` and `requiredStableFor` are seconds. `result.wallMs`, `result.maxWriteMs`, `result.timing`, a timeline's `at`, and `receivedAt` are milliseconds. `result.tolerance` is points. Dates are ISO 8601 strings.

### Exit codes

- `0`: the command did what was asked. For a change, the operation finished with outcome `complete`. For `result`, the operation it names finished with outcome `complete`. For `wait-settled`, the Space was settled. For every other command, the reply had `ok` true.
- `1`: anything else: a refusal (including `same-space`), an operation that finished with another outcome, `timeout`, `protocol-error`, and `result` while its receipt is still `pending`, even though `ok` is true there.
- `2`: the CLI could not communicate with LazySpace (`connection-unavailable` or `control-unavailable`).

### Outcomes

| Outcome | Meaning |
|---|---|
| `complete` | Everything was done and read back as requested. The only outcome that exits 0. |
| `partial` | Part of it was done. `stopReason`, each target's `status`, and `message` say what was not. |
| `interrupted` | Stopped partway; `stopReason` says why. What was already written stays. |
| `notPossible` | It could not be done; `stopReason` and `message` say why (for example, Accessibility access is missing, or the window changed after the request). Usually nothing changed, but not always: a Space switch can stop on a Space in between, and an arrangement that did not fit can have moved windows and put them back. Read the desktop again before retrying. |
| `nothingToDo` | Nothing was written. Usually nothing needed to change. With `stopReason` `appUnresponsive`, an app did not answer and LazySpace waited for it instead of arranging the other windows. |

`stopReason`, when present, is one of these:

| Stop reason | Meaning |
|---|---|
| `paused` | LazySpace was paused. |
| `userInput` | The user pressed a key, clicked, dragged, or scrolled. |
| `spaceChanged` | The current Space changed. |
| `permissionLost` | Accessibility access was lost. |
| `targetsChanged` | The windows changed after the request: one closed, left the Space, or no longer matches its process or app. |
| `appUnresponsive` | An app did not answer in time. |
| `cancelled` | LazySpace called the operation off (for example, automatic arrangement was turned off for the Space), or held a write back because a mouse button was down or automatic arrangement stopped being available. |

### Why a window is excluded

In `list-windows --json`, `excluded[].reason` is text for people. The structure says why: LazySpace checks `window.membership` first, then `window.kind`.

- `membership`: `current` (this Space), `other` (another Space), `otherDisplay` (a display without the menu bar, while displays share one Space), `allSpaces` (shown on every Space), or `unknown` (the Space cannot be determined).
- `kind`: `standard` (can be arranged), `dialog` (fixed size), `sheet`, `palette` (a tool palette or floating panel), `minimized`, `hiddenApp`, `fullscreen` (full screen or Split View), `nonNormalLayer` (not a standard window), or `unknownRole` (the window type cannot be determined).

A `standard` window on the `current` Space can still be excluded: by a rule in the configuration, because it floats (its ID is in `status.floating`), or while LazySpace classifies it or confirms a send to another Space. Only `reason` tells these apart. In an operation's `result.excluded`, `code` is `overflowFloat` for a window kept in place as floating because the layout did not fit the work area even at minimum sizes.

### Why automatic arrangement is unavailable

`status.autoAvailable` says whether automatic arrangement can run. When it is false, `status.autoUnavailableCause` names the reason that `autoReason` gives in words: the first condition that is not met, in this order. Pausing (`paused`, `currentSpaceAutoPaused`) is separate and is not a cause. Read `autoAvailable` itself, not the absence of a cause.

| Cause | Meaning |
|---|---|
| `accessibility` | Accessibility access is not granted (`trusted` is false). |
| `spaceObservation` | LazySpace cannot detect Spaces on this Mac (`spaceObservation` is false). |
| `inputMonitoring` | LazySpace is listed in Input Monitoring and turned off, so it cannot observe keyboard and mouse input. |
| `inputObservation` | LazySpace cannot observe keyboard and mouse input for another reason. It tries again every few seconds. |
| `configNotApplied` | No configuration file has been applied since launch, because the file could not be read or had an error then (`configError`). |
| `stageManager` | Stage Manager is on. |
| `sharedSpaces` | More than one display is connected and "Displays have separate Spaces" is off. |

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
- A reply that cannot be written as JSON is replaced by `internal-error`, which keeps the reply's `requestID` and `operationID` and exits 1.

After a lost reply or a restart, do not make up a replacement token. Query the same token. Or look at the desktop, and reserve a new token only if you intend to make a new change.

## Codes

Each `code` describes this attempt. Whether an earlier attempt changed something is a separate question:

- After `connection-unavailable`, `control-unavailable`, `timeout`, or `protocol-error` while a change was being sent, the change may have run. If the output has a `requestID`, query it with `lazyspace result <requestID>` before doing anything else. Do not send the same change again with a new token to retry it.
- A refusal stays attached to its receipt: sending the same token again returns the same refusal, so a new attempt needs a new token.
- After `session-mismatch` or `request-expired`, the outcome is gone. Look at the desktop before deciding on a new change.

### Communication and arguments

| Code | What happened | What to do |
|---|---|---|
| `usage` | The CLI or the app rejected the arguments or the request. Nothing ran. | Fix the command. Do not resend it unchanged. |
| `connection-unavailable` | No running LazySpace answered (exit 2). | If the output has a `requestID`, query it once LazySpace answers again. Otherwise LazySpace is not running; tell the user. |
| `control-unavailable` | LazySpace holds its instance lock, but the CLI could not talk to it (exit 2). | As for `connection-unavailable`. In a sandbox, run the command outside it. Otherwise, check the support folder's ownership and permissions, and that `LAZYSPACE_SUPPORT` matches the app's. |
| `unauthorized` | The app did not accept the request's credential. The CLI always sends the current one, so the request did not come through the CLI. Nothing ran. | Send requests through `lazyspace`. |
| `invalid-request` | The app could not read or resolve the request. Nothing ran. | The CLI and the running app may differ; restart LazySpace. |
| `unknown-command` | The running app does not know the command. Nothing ran. | The running app is older than the CLI; restart LazySpace. |
| `protocol-error` | A reply did not match what the CLI is tracking, or used a schema it does not read. The CLI did not resend anything. | Query the `requestID`, if any. Restart LazySpace if it was just updated. |
| `timeout` | `wait-settled` did not see a settled Space in time, `list-windows` did not finish within 30 seconds, or a change's result did not arrive within 120 seconds. | For `wait-settled`, read `settlement.blockers`. For a change, query its `requestID` before sending anything else. |
| `internal-error` | Something failed inside LazySpace or the CLI, including a reply that could not be written as JSON. | Query the `requestID`, if any, and tell the user. Do not retry in a loop. |

### Receipts

| Code | What happened | What to do |
|---|---|---|
| `reserved` | `request-token` reserved a token. | Send one change with `--request-id`. |
| `pending` | The change is still running. `ok` is true, but `result` exits 1. | Query `result` again. |
| `finished` | The operation ended. | Read `ok` and `result.outcome`. |
| `request-capacity` | 64 reservations and running changes are already held. Nothing was reserved. | Wait for running changes to finish or unused tokens to expire, then reserve again. |
| `request-sequence-exhausted` | This LazySpace session cannot hand out another token. | Restart LazySpace. |
| `unknown-request` | The token was never reserved in this session. Nothing ran. | Reserve a token with `request-token`. Never make one up. |
| `request-not-submitted` | `result`: the token is reserved, but no change was sent with it. | Send the change with it, or let it expire. |
| `request-conflict` | The token is already bound to a different change. Nothing ran for this request. | Use a new token. |
| `request-expired` | The receipt expired or was evicted. It will never run again, and its outcome is gone. | Look at the desktop (`list-windows`) before deciding on a new change. |
| `session-mismatch` | The token belongs to an earlier LazySpace session. The change may have happened; its outcome is gone. | Look at the desktop. Reserve a new token only for a new change. |
| `unknown-operation` | `result`: the operation ID is unknown or no longer kept (the latest 32 results are kept). | Query the receipt's `requestID` instead, if you have one. |

### Refusals

The change was not started, and nothing was changed.

| Code | What happened | What to do |
|---|---|---|
| `busy` | Another operation is running. | Wait (`wait-settled`), then try again with a new token. |
| `space-mismatch` | The current Space is not the one in `--expect-space-id`: the user switched Spaces. | Read `status` and `list-windows` again, and decide again. |
| `target-not-found` | The `--window-id` window (with `--expect-pid`, in that process) is not on the current Space: it closed, moved, or the ID now belongs to another process. For `move-to-space`, the window to send is not on the current Space. | Read `list-windows` again. |
| `paused` | LazySpace is paused in every Space. | Tell the user. Run `resume` only if the user wants it. |
| `input-changed` | The request was checked against the desktop when it arrived, and the user had pressed a key or used the mouse since. | Decide whether the change is still wanted, then use a new token. |
| `space-changed` | As above, but the current Space had changed. | Read `status` and `list-windows` again. |
| `targets-changed` | As above, but the target window no longer matched (it closed, left the Space, or belongs to another process or app). From the menu: the selected window changed. | Read `list-windows` again. |
| `permission-lost` | As above, but Accessibility access was lost. | Tell the user. |
| `app-unresponsive` | As above, but the window's app did not answer in time. | Try again later, or tell the user. |
| `cancelled` | As above, but LazySpace had called pending work off (for example, a command replaced an automatic arrangement, or automatic arrangement was turned off for the Space). | Read the desktop again before deciding. |
| `not-started` | This Space has no layout yet. | `arrange` creates one, if the user wants this Space arranged. |
| `no-focused-window` | No focused window was found, and no `--window-id` was given. | Pass `--window-id`. |
| `not-tiled` | The window floats, is excluded, or is waiting, so layout edits do not apply to it. | Use `float off` or `integrate`, or pick another window. |
| `layout-unavailable` | The saved layout could not be fitted to the work area. | Run `arrange`, or tell the user. |
| `no-neighbor` | There is no window in that direction. | Nothing to do. |
| `single-window` | `resize` with only one window in the layout. | Nothing to do. |
| `nothing-to-undo` | There is no layout change to undo. | Nothing to do. |
| `no-focus-history` | `focus back` has no earlier window on this Space. | Nothing to do. |
| `same-space` | Already on that Space (`space`), or the window is already there (`move-to-space`). Exits 1. | Treat it as done. |
| `space-not-found` | The destination does not exist: no such desktop on that display, no Space in that direction, no earlier Space for `back`, no such display, or the Space is gone. | Read `list-spaces` again. |
| `space-unavailable` | LazySpace cannot detect Spaces on this Mac. | Tell the user. |
| `send-unavailable` | `move-to-space` without `--follow` needs a direct move that this macOS does not offer. | Use `--follow`. |

### Other commands

| Code | What happened | What to do |
|---|---|---|
| `unknown-mode` | `mode NAME`: the configuration declares no such mode. | Read `status.modes`. |
| `config-error` | `reload`: the configuration file has an error, and the previous configuration stays in use. | Read `status.configError`. |
| `resume-unavailable` | `resume`: LazySpace stays paused, because Accessibility access is missing, the layout could not be confirmed, or an app did not answer. | Read `message`. Try again later, or tell the user. |

## Waiting for the desktop to settle

`idle` in `status` only tells you that the queue and mouse handling are quiet. To wait for the Space itself, use `wait-settled`.

`wait-settled` takes fresh observations on the operation queue and checks for arrival handling, input, and deferred automatic work. Each call starts its own waiting interval. It finishes when the windows of the current Space have stayed unchanged for at least one second, or for the configured `quiet-interval` if that is longer. Its `settlement` field includes the observation time, the Space, the stable interval, and anything that blocked it (`blockers`):

| Blocker | Meaning |
|---|---|
| `operations-or-mouse` | An operation is running or queued, or a mouse interaction is being handled. |
| `space-unavailable` | The current Space could not be read, or it changed during the observation. |
| `accessibility-unavailable` | Accessibility access is not granted. |
| `input` | The user pressed a key or used the mouse within the quiet interval. |
| `arrival` | The current Space was entered less than a second ago. |
| `deferred` | Handling of a window that opened or closed is deferred or waiting to be retried. |
| `auto-start` | Automatic arrangement is about to start on this Space. |
| `observing` | The windows have not stayed unchanged for `requiredStableFor` yet. |

A finished `wait-settled` means the Space was observed to be stable. It does not lock the desktop and says nothing about what apps will do next.
