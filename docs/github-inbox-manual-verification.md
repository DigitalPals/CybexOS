# GitHub Inbox manual verification

Use an authenticated `gh` account with access to public and private repositories,
including at least one repository with GitHub Actions and Discussions enabled.
Keep the GitHub module enabled unless a step explicitly says otherwise.

## Inbox lifecycle and cadence

- [ ] Open the GitHub module settings at the normal panel width. **Recent
  account repos** stays inside its label column, and the Badge, slider, CI, and
  toast controls remain aligned.
- [ ] Open the GitHub popover. **Inbox** is selected by default;
  **Repositories** still opens the repository browser and commit drill-down.
- [ ] On a fresh state file, let notifications, events for each repository,
  and workflows for each repository complete their first successful response.
  Existing rows appear under collapsed **Settled** (live workflows remain in
  **Active**) and the bar has no Inbox badge.
- [ ] Trigger a workflow and observe queued/requested/waiting/pending and then
  in-progress state in **Active**. Active rows have no Settle action and do not
  increase the Inbox badge; the static bar marker appears without pulsing.
- [ ] Leave it active for more than 30 seconds. Its state refreshes on the fast
  workflow-only cadence, for at most five active repositories.
- [ ] With no active workflow, observe a full Inbox sweep at roughly 60 seconds.
  It includes directed notifications and repository events. Repository
  discovery still uses **Repo refresh**, and event requests honor GitHub's
  `X-Poll-Interval` when it is longer than a minute. A quiet repository's
  workflow runs are read once per **Repo refresh** interval; they are read
  every sweep only while one of its runs is active or for three minutes after
  its events report a push, pull request, new branch or tag, or release. A
  manual refresh reads every repository's runs.
- [ ] Complete one workflow successfully and one with failure or
  action-required. Success moves to **Updates**; failures move to **Attention**
  in red, and action-required uses amber.
- [ ] Confirm cancelled, skipped, and neutral completions appear in **Updates**
  with muted styling, while timed-out/startup-failed runs use **Attention**.

## Repository events

- [ ] Push twice to the same branch. One branch entity appears under
  **Updates**; after settling it, the second push replaces the snapshot and
  wakes it. Pushes to a second ref create a separate entity.
- [ ] Create and delete both a branch and a tag. Each ref has one stable row,
  the latest lifecycle action is shown, and its browser link is useful even
  after deletion.
- [ ] Open, close, and reopen an issue. Repeat for a pull request, including a
  merge. Each number remains one entity whose newer lifecycle wakes a settled
  row and whose card opens the issue or pull request.
- [ ] Publish a release and create a discussion. Both appear in **Updates** and
  open the release/discussion page. Draft releases and discussion edits do not
  appear.
- [ ] Generate comments, reviews, assignments, labels, stars, forks, wiki
  edits, and collaborator changes. None creates a repository-event row; a
  user-directed notification can still appear through GitHub notifications.
- [ ] Repeat representative checks for a private repository. No private API
  payload beyond the rendered snapshot is written to the local state file.

## Settlement, emphasis, and persistence

- [ ] Hover an unsettled row and use the accessible **Settle** check action.
  The row moves into the collapsed **Settled** drawer and its badge contribution
  disappears. Expand the drawer, hover or keyboard-focus the row, and use
  **Unsettle** to return it to **Attention** or **Updates**.
- [ ] Click the row outside its Settle/Unsettle icon. It still opens the GitHub
  URL; using the local action does not activate the row.
- [ ] Close the popover with several pending rows. Their bold/unread emphasis
  clears, but the bar badge and unsettled lifecycle persist until settlement.
  Repository-tab dots also clear independently and never add to the bar badge.
- [ ] Set Badge to **Dot**, **Count**, and **Off**. Red wins for pending
  failures/security, amber for other pending attention, and accent for general
  updates. Count caps at `99+`; Badge Off still leaves the live marker visible.
- [ ] Hover the bar icon and confirm it separately reports live workflows,
  pending Inbox entities, and view-based repository updates.
- [ ] Restart Quickshell with pending and settled rows. Both lifecycles survive,
  the badge does not flood, and an unchanged API revision remains settled.
- [ ] After restart, cause new activity on a settled issue, pull request,
  notification thread, workflow run, or push ref. Its safe snapshot is replaced
  and returns to the active Inbox as unsettled.
- [ ] Accumulate more than 30 pending rows. None disappears. Settle all of them
  and confirm only the 30 most recently settled snapshots remain in the drawer.
- [ ] Confirm Settle/Unsettle never marks a GitHub notification read or done and
  does not cause any GitHub mutation visible in audit/API traffic.

## Toasts and workflow option

- [ ] Discover a pre-existing failed run on a clean state file. It does not
  toast. Cause a running/new attempt to fail: one GitHub toast appears. Restart
  Quickshell and confirm that attempt does not toast again.
- [ ] Cause multiple workflows to fail in one sweep. One coalesced toast
  appears. Routine Inbox events, starts, and successful workflows never toast.
- [ ] Confirm watched-repository push toasts are unchanged and remain separate
  from general push-event Inbox rows.
- [ ] Turn off **Toasts** and confirm it suppresses watched-push and failed or
  action-required workflow toasts.
- [ ] Turn off **CI reports**. Workflow polling, new workflow rows, toasts, and
  the live marker stop immediately; existing settleable snapshots remain local
  until settlement. The 60-second repository-event and notification polling
  continues. Turn CI reports back on; newly discovered completions form a quiet
  baseline without implicitly settling an existing pending row.

## Scope, navigation, and keyboard

- [ ] Set a small **Recent account repos** count, then watch an older account
  repository and an outside repository. Both remain additive in
  **Repositories** and in repository-event/workflow scope.
- [ ] Use manual refresh. Repository discovery and Inbox checking begin without
  duplicate queued reads. Expand a commit while the background queue is busy;
  interactive commit/stat reads complete before remaining background jobs.
- [ ] Tab to **Inbox** and **Repositories**, use Left/Right and Enter/Space, and
  confirm assistive names expose them as selected page tabs.
- [ ] Confirm Inbox rows show only a coloured status glyph and meaningful title.
  Workflow rows use GitHub's run display title instead of a generic workflow
  name such as `CI`. Needs-you and error rows have no resting fill or border;
  their glyph alone carries the semantic colour. Hidden non-workflow detail
  remains present in the accessible name.
- [ ] Confirm repository and collapsed commit rows remain one compact line:
  title first, bounded context next, status/time at the right.
- [ ] In **Repositories**, activate a row to drill into commits, then use its
  revealed **Open repository on GitHub** icon to open the repository directly.
- [ ] Keyboard-focus an Inbox row, Tab to its revealed settlement action, and
  operate both Settle and Unsettle with Enter/Space. Row activation still opens
  the browser. The settled drawer itself is keyboard operable and announces its
  expanded/collapsed state.
- [ ] Drill into **Commits** and press Escape to return to **Repositories**.
  Escape on either top-level tab closes the popover.

## Conditional requests and failures

- [ ] Inspect event API traffic after a successful `200`. The next eligible
  request sends the exact ETag (including a weak `W/` prefix). A `304` is
  treated as success despite `gh --jq` returning nonzero for its empty body,
  and cached rows remain unchanged.
- [ ] Repeat for workflow runs and repository discovery (`/user/repos` and
  each outside watch), all with `If-None-Match`, and for notifications
  (`If-Modified-Since`). A `304` keeps the rows; notifications are not polled
  sooner than the server's `X-Poll-Interval`. Mark a notification read on
  github.com and confirm it leaves the Inbox once `Last-Modified` moves.
- [ ] With `x-ratelimit-remaining` below 200, the Inbox shows "GitHub API quota
  is low; Inbox checks resume in N minutes" and timers stop invoking `gh` until
  the reset; a manual refresh still runs.
- [ ] Blackhole the network mid-request (for example drop traffic to
  api.github.com). A stalled `gh` is killed after 60 s (30 s for an interactive
  commit/stat read), the job fails with "timed out", and the queue moves on.
- [ ] Remove event or Actions permission from one monitored private repository.
  Other sources and cached rows remain visible; the repository-specific error
  appears in the popover and settings.
- [ ] Use a credential without notification access. Repository events, commits,
  and permitted workflow data continue while notifications report unavailable.
- [ ] Break connectivity while NetworkManager still reports it online (as
  above), or exhaust the API rate limit. Cached Inbox rows remain visible, the
  global error reports a paused Inbox, and retries back off instead of
  continuously invoking `gh`.
- [ ] Change recent-repository count or watch list during a slow sweep. Results
  from the obsolete scope do not reappear after the new scope loads.
- [ ] Disable the GitHub module for more than one minute. Neither the 60-second
  full timer nor the 30-second active timer invokes `gh`.
- [ ] Leave the session without input for five minutes (locked or not), or
  disconnect through NetworkManager. No scheduled `gh` process starts while
  it stays idle or offline. The first input, or the reconnect, starts a sweep
  at once; it reads only what is due.
