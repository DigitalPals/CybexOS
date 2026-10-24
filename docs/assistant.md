# NerdOS Assistant

The assistant is a round character that floats above every window. Ask it
about NerdOS by typing or by holding a key and talking; it answers in a small
box under itself. It can change desktop preferences, create personal widgets,
prepare system changes for review, write small programs and answer general
questions. The work is done by the coding agent the person already uses:
Claude Code or Codex. NerdOS never stores their credentials.

The assistant is summoned, never proactive. It does not watch the screen,
listen or speak unless asked to for one question.

## Using it

- **Connect an account first.** When the selected agent is not signed in,
  opening the assistant shows setup with **Sign in to Claude Code** and
  **Sign in to Codex**. Each button opens that agent's own sign-in in your
  chosen terminal and browser. The box checks for completion automatically;
  **Check sign-in** also works after signing in elsewhere. Your draft stays
  in the box until you send it. Missing agents link to Software.
  Settings → Assistant also shows sign-in status. Automatic selection prefers
  an installed, signed-in agent.
- **Show or hide** the character from its menubar button (the sparkles beside
  the notifications) or with `nerd assistant toggle`. The button shows `…`
  while a question is being worked on, `!` while one needs your answer and a
  dot for a reply you have not seen. Drag the character anywhere, including to
  another display. It stays where it was left, across sessions, and keeps out
  of the way while game mode is on.
- **Ask** by hovering the character, or tap `Super+I`, then type and press
  Enter. Hovering opens the box without taking the keyboard; clicking it or
  the shortcut does.
- **Talk** by holding `Super+I` (or the microphone button) and releasing it to
  send. The words are transcribed locally by Voxtype; no audio leaves the
  computer. `Esc` or the cancel button discards a recording.
- **While it works** the character shows a spinning arc and a short line about
  the current step. Clicking the character while it works tucks the box away;
  a lime dot appears when the reply is ready.
- **Replies** stay under the character until closed. Copy, Reply (continue the
  conversation), Speak, Undo (when it changed preferences or files), and
  Continue in a terminal (opens the same Claude Code or Codex session in
  Kitty, for longer coding work) appear under a reply.
- **From a terminal**, `nerd assistant ask "…"` asks the same assistant and
  prints the reply; anything it needs approved still appears on screen.
  `nerd assistant status` prints the service's state as JSON.
- **Screen context**, when enabled in Settings → Assistant, adds a screen
  button to the box. It attaches one screenshot of the display the character is
  on, taken with the character hidden, to that one question. The image is
  deleted when the reply finishes.

## What it may do without asking

Every tool call the agent makes passes through the assistant's approval policy
(`desktop/assistant/nerdos_assistant/policy.py`):

| Action | Decision |
| --- | --- |
| Reading files, searching, web search and fetch | Allowed |
| Read-only commands (`ls`, `cat`, `rg`, `jq`, `hyprctl -j …`, `nerd update status`, `nerd plugin list`, `systemctl --user status`, …) | Allowed |
| Editing desktop preferences (`~/.config/nerdos/…`) and personal plugins (`~/.local/share/nerdos/plugins/…`) | Allowed; the reply offers **Undo** |
| Staging a system change (`nerd update stage local`, `nerd software stage …`) | Allowed; administrator authentication is still requested by polkit |
| Applying a staged change (`nerd update apply …`) | A review card with the actual package changes; **Apply…** then asks for the administrator password |
| Vendor files (`/nix/store`, `/etc/nerdos`, `/run/current-system`) | Refused |
| `nixos-rebuild`, `sudo`, rebooting or powering off | Refused |
| Any other command or file edit | An approval card: Allow once, Allow for this conversation, or Deny |

The person's own agent settings still apply on top: a rule in
`~/.claude/settings.json` that already allows a tool is honored by Claude
Code. Codex runs with a read-only sandbox and asks for every write or
escalation, which reaches the same cards.

New widgets are created disabled. When a reply created one, **Add to bar**
enables it with `nerd plugin enable`.

## Settings

Settings → Assistant, stored in `~/.config/nerdos/shell.json`:

| Key | Values | Default |
| --- | --- | --- |
| `assistantAgent` | `auto`, `claude`, `codex` | `auto` (the `nerd agent` default when it is Claude Code or Codex, else whichever is installed) |
| `assistantClaudeModel` | `default`, `fable`, `sonnet`, `opus` | `default` |
| `assistantCodexModel` | `default`, `gpt-5.6-luna`, `gpt-5.6-terra`, `gpt-5.6-sol` | `default` |
| `assistantSpeak` | spoken replies | `false` |
| `assistantScreenContext` | offer the screen button | `false` |
| `assistantCharacter` | `mascot`, `mark` | `mascot` |
| `assistantShown` | the character is on screen | `false` |
| `assistantScreen`, `assistantX`, `assistantY` | where it was left | primary display, top right |

### The character

`mascot` is the NerdOS glasses as a character, with eyes behind the lenses.
`mark` shows the unchanged logo, and only the ring around it shows what the
assistant is doing.

The brand guide (`assets/brand/USAGE.md` §8) forbids eyes or faces in the
logo's lenses, and it still applies: the mascot is a separate character, not a
variant of the logo, and is used only as the assistant on screen. Its rules:

- It is drawn from the master symbol's own geometry and colours
  (`assets/brand/symbol/svg/nerdos-symbol-on-dark.svg`) on a charcoal disc; the
  frames, the tape and its angle never change.
- The eyes are plain off-white pills behind the lenses, cropped by the frames.
  They may move, blink, close to a curve when happy or asleep, and widen when
  listening. No pupils, mouths, eyebrows, reflections or extra colours.
- Lime stays on the tape and the activity ring; amber marks only a question
  waiting for an answer.
- Wherever the logo appears as the logo (the menubar's Control Center button,
  the boot splash, documents), it is the unchanged mark.

## Installation

`nerdos.features.assistant` (default on) installs the service, Codex, and
Claude Code when proprietary applications are selected too. It does not need
the developer tooling feature. Voxtype, Pipewire and speech-dispatcher are part
of every installation. Turning the feature off removes the menubar button,
the shortcut and the service; nothing in `shell.json` is lost.

## Architecture

- `desktop/assistant/nerdos_assistant/` — the `nerdos-assistant` service, a
  user unit (`nerdos-assistant.service`). It owns the agent processes so a
  Quickshell restart, including one caused by the assistant's own changes,
  does not end a turn. Only the standard library is used.
  - `server.py` — the socket and the session state.
  - `auth.py` — bounded, output-discarding `claude auth status` and
    `codex login status` checks. No prompt or model request checks sign-in.
    Login runs `claude auth login` or `codex login` in a terminal;
    credentials remain with the provider CLI, outside the assistant and store.
  - `claude.py` — Claude Code over `--input-format stream-json` with
    `--permission-prompt-tool stdio`: every permission prompt arrives as a
    `can_use_tool` control request and is answered by the policy or a card.
  - `codex.py` — `codex app-server` (JSON-RPC over stdio): threads, turns,
    and `item/*/requestApproval` server requests.
  - `policy.py` — the table above, and the file snapshots behind Undo.
  - `speech.py` — speech-dispatcher's SSIP socket, one sentence per message
    so the reply can follow along.
  - `prompt.py` — the instructions appended to the agent's own system
    prompt.
- `desktop/quickshell/Common/Assistant.qml` — the shell's client: connection,
  turn state, voice, screen capture and placement.
- `desktop/quickshell/AssistantWindow.qml` and `Assistant/` — the overlay
  surface, the character, the composer, the working pill and the reply card.
- `desktop/quickshell/Bar/Modules/Assistant.qml` — the menubar button.

State lives in `~/.local/state/nerdos/assistant/state.json` (the current
conversation id per agent and the last finished reply). Screenshots live in
`$XDG_RUNTIME_DIR/nerdos/assistant/` only for the question that used them.

### Protocol

`$XDG_RUNTIME_DIR/nerdos/assistant.sock` (directory `0700`) carries JSON-RPC 2.0,
one UTF-8 JSON object per line. Every connected client receives every
notification. Lines are limited to 4 MiB.

Requests:

| Method | Params | Result |
| --- | --- | --- |
| `hello` | `{client, protocol: 1}` | `{protocol, agents, turn, conversation, speech}` |
| `auth.status` | `{}` | `{agents}` — refresh installation/sign-in status |
| `auth.login` | `{agent: "claude" \| "codex"}` | `{argv, cwd}` — the agent's own login command for a terminal |
| `turn.start` | `{text, agent, model?, screenshot?, context?}` | `{turn}`; error `-32001` while a turn runs |
| `turn.stop` | `{}` | `{stopped}` |
| `approval.respond` | `{id, decision: "allow" \| "always" \| "deny"}` | `{ok}` |
| `turn.undo` | `{id}` | `{restored: [path], skipped: [path]}` |
| `conversation.reset` | `{}` | `{ok}` |
| `conversation.handoff` | `{}` | `{argv, cwd}` — the terminal command that resumes the session |
| `speech.say` | `{text, language?}` | `{id, sentences}` |
| `speech.stop` | `{}` | `{ok}` |

`agents` is `{claude: {available, label, auth}, codex: {available, label, auth}}`.
`auth` is `ready`, `required`, `unknown` (the bounded status check failed), or
`missing`. Status output and credentials are never exposed through this
protocol or saved in assistant state. `turn.start` returns `-32004` before
starting a model when the selected installed agent needs sign-in. A CLI that
rejects an existing credential also marks that agent as requiring sign-in.
`context` is `{output, speak, language}`: the display the question was asked
on, whether the reply will be spoken (the agent then keeps it short and
avoids tables and code), and the shell's language.

Notifications:

- `turn.updated {turn}` — a complete snapshot after any change except text.
- `agents.updated {agents}` — refreshed installation/sign-in status.
- `turn.delta {id, text}` — reply text appended while streaming.
- `speech.progress {id, index}`, `speech.done {id, status}`.

A turn snapshot:

```json
{
  "id": "t-3f2a…",
  "agent": "claude",
  "prompt": "Make the menubar transparent",
  "status": "running | waiting | completed | stopped | failed",
  "step": "Editing shell.json",
  "text": "…",
  "error": "",
  "errorKind": "auth | missing | crashed | ''",
  "approvals": [{"id": "a-1", "kind": "command | edit | apply | other",
                  "title": "Run a command", "detail": "…", "command": "…",
                  "path": "…", "diff": "…", "transaction": "…", "changes": "…",
                  "ready": true}],
  "startedAt": 1761223000000,
  "finishedAt": 0,
  "undo": ["~/.config/nerdos/shell.json"],
  "plugins": [{"id": "personal.cputemp", "name": "CPU temperature"}],
  "staged": "8f3a2c…",
  "screenshot": false,
  "resumable": true
}
```

`ready` (apply cards only) is true when the lifecycle status shows that
transaction built and checked. Errors: `-32001` busy, `-32002` no such
pending approval or nothing to undo, `-32003` nothing to resume, `-32602`
invalid params (including a screenshot outside
`$XDG_RUNTIME_DIR/nerdos/assistant/`, which the service creates `0700` and
empties when it starts), `-32601` unknown method.

The service never replays a request after a reconnect; the shell sends
`hello` and adopts the snapshot it returns.

Authentication commands follow the official [OpenAI authentication
documentation](https://developers.openai.com/codex/auth/) and [Claude Code CLI
reference](https://code.claude.com/docs/en/cli-reference).
