# T3 composer manual verification

Use a connected T3 Code server with at least one provider that advertises a
select trait and a boolean trait.

## Disclosure and layout

- [ ] Open an existing thread and New Thread. Confirm each uses one rounded
  glass composer: prompt above, compact model/reasoning/access controls below,
  and a circular send arrow at the lower right.
- [ ] Open New Thread and confirm the prompt starts focused with its placeholder
  still visible, typing lands immediately, and `Escape` still returns to the
  inbox.
- [ ] Activate the tune/summary row and confirm the Run settings drawer attaches
  immediately above the composer. Leave the page, reopen it, and confirm the
  drawer resets to collapsed instead of persisting the previous choice.
- [ ] Confirm the toolbar stays one row: model text elides before access text,
  while the tune and send/stop actions never clip. Run settings must have a
  Tabler close control rather than a typographic chevron.
- [ ] Confirm `Full access` is amber in both the toolbar chip and expanded Access
  picker. Below 360px of effective composer width, confirm reasoning moves into
  Run settings while model and access remain available in the toolbar and its
  accessible description.
- [ ] On New Thread, confirm Project appears as a compact shoulder directly
  above the composer rather than as a separate full-page form section.
- [ ] Confirm expanded controls use the wider T3 panel's available columns and
  stack without horizontal clipping on an output-constrained width. On a short
  screen, confirm the content-sized panel stops at the output cap and its form,
  transcript, attachment, and picker scroll areas remain usable.

## Input and state

- [ ] Toggle the settings row with the mouse, then use `Tab`, `Enter`, and
  `Space`; confirm keyboard focus has a visible ring and the drawer follows the
  state.
- [ ] Repeat while the composer is read-only, running, or sending; the header
  must still open for inspection while each setting remains disabled.
- [ ] Tab through provider, model, access, mode, select traits, boolean traits,
  prompt, and Send. Exercise picker open/close, arrow-key selection, and
  `Escape`.
- [ ] Open every picker in both New Thread and an existing thread. Confirm its
  menu is opaque and stays above the other settings, prompt, buttons, and error
  text; opening a second picker must close the first. Reopen it and click
  elsewhere in the drawer without selecting an option; the menu must close and
  the underlying control must still receive that click. Selected options should
  show a check and the first nine choices should show shortcut numbers.
- [ ] Test idle, running, read-only, sending, plan-ready, and provider-locked
  threads. Confirm the prior enablement, model-locking, prompt, and send behavior
  is unchanged.
- [ ] Change provider/model and confirm the traits and summary chips update.
  Confirm Mode only appears when supported, and exercise every advertised
  select and boolean trait.
- [ ] Select Ultrathink and confirm prompt injection and the prompt highlight
  still work. Trigger a trait validation error and confirm it remains visible in
  the open settings drawer.
- [ ] On a thread with an approval or structured question, confirm the request
  is in a bounded drawer immediately above the composer—not in the transcript—
  and that overflow remains scrollable. Repeat with a ready plan.

## Automated and runtime checks

- [ ] Run `tests/run` (Node tests plus qmllint over the whole shell).
- [ ] Deploy through the Quickshell Ansible tag with `qs_live_begin` /
  `qs_live_end`; inspect that service invocation's journal for QML load
  failures, syntax errors, binding loops, invalid sizing, and oversized buffers.
