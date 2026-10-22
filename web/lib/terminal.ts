import type { AppId } from './types';

export const HOME_PATH = '/home/guest';
export const README_CONTENT = `Welcome to NerdOS
==================

NerdOS — the Opinionated System is a Hyprland desktop built around
a fast keyboard-first workflow, Quickshell, and a coherent theme.

This browser experience recreates the feel of the desktop.
It is an interactive preview, not a running Linux machine.

Things to try
------------
• Open a few apps and watch them tile into place.
• Use Alt + arrows to focus a neighboring tile.
• Switch workspaces from the top bar.
• Change your theme in Settings.
• Write something in Omawrite. Notes stay in this browser.
• Type help in the terminal to explore supported commands.

Source: https://github.com/DigitalPals/NerdOS
`;

export const SHORTCUTS_CONTENT = `NerdOS browser shortcuts
========================

Alt + Space               Open the launcher
Alt + 1–5                 Switch workspace
Alt + Shift + 1–5         Move focused window (stay here)
Alt + Enter               Open terminal
Alt + K                   Open keyboard shortcuts
Alt + arrows              Focus a neighboring tile
Alt + Shift + arrows      Swap neighboring tiles
Alt + V                   Toggle floating / tiling
Alt + F                   Maximize / restore
Escape                    Close the launcher or an open panel

Windows
-------
Apps tile automatically. Drag a tile's title onto another
window to swap them. Drag a floating title to move it.
Use the floating control, then drag a corner to resize.
Drag the main divider, or open Tiling layout in the footer,
to adjust the split.
Double-click a title to maximize or restore.

Terminal
--------
↑ / ↓                     Browse history (keeps your draft)
Tab                       Complete commands and sample paths
Ctrl + C                  Cancel the current command
Ctrl + L                  Clear terminal output
Ctrl + U                  Clear the command line

Native Hyprland uses Super-based shortcuts. This browser
preview adapts them to Alt. Your browser or desktop may
reserve some combinations; clickable controls are available.
See the Keyboard Shortcuts app for all preview shortcuts.
`;

export type VirtualFile = {
  name: string;
  kind: 'folder' | 'text' | 'image' | 'note';
  description: string;
  content?: string;
};

export const FILE_SYSTEM: Record<string, VirtualFile[]> = {
  '/': [{ name: 'home', kind: 'folder', description: 'Folder' }],
  '/home': [{ name: 'guest', kind: 'folder', description: 'Folder' }],
  [HOME_PATH]: [
    { name: 'Documents', kind: 'folder', description: '2 items' },
    { name: 'Downloads', kind: 'folder', description: 'Empty folder' },
    { name: 'Pictures', kind: 'folder', description: '1 image' },
    { name: 'Code', kind: 'folder', description: '1 item' },
    { name: 'Welcome.txt', kind: 'text', description: 'Text document', content: README_CONTENT },
  ],
  [`${HOME_PATH}/Documents`]: [
    { name: 'My notes.md', kind: 'note', description: 'Open in Omawrite' },
    { name: 'Shortcuts.txt', kind: 'text', description: 'Text document', content: SHORTCUTS_CONTENT },
  ],
  [`${HOME_PATH}/Downloads`]: [],
  [`${HOME_PATH}/Pictures`]: [
    { name: 'moon-mountains.jpg', kind: 'image', description: 'Desktop wallpaper' },
  ],
  [`${HOME_PATH}/Code`]: [
    { name: 'README.md', kind: 'text', description: 'Markdown document', content: '# Make it yours\n\nA workspace for your next idea.\n\nExplore the desktop, image builder, and documentation at:\nhttps://github.com/DigitalPals/NerdOS\n\nThis is a sample folder in the browser preview.\n' },
  ],
};

export function resolvePath(input: string, cwd: string): string {
  const expanded = input === '~' ? HOME_PATH : input.startsWith('~/') ? `${HOME_PATH}/${input.slice(2)}` : input;
  const absolute = expanded.startsWith('/') ? expanded : `${cwd}/${expanded}`;
  const parts: string[] = [];
  for (const part of absolute.split('/')) {
    if (part === '..') parts.pop();
    else if (part && part !== '.') parts.push(part);
  }
  return `/${parts.join('/')}`;
}

export function displayPath(path: string): string {
  return path === HOME_PATH ? '~' : path.startsWith(`${HOME_PATH}/`) ? `~${path.slice(HOME_PATH.length)}` : path;
}

function tokenize(input: string): string[] | null {
  const tokens: string[] = [];
  let token = '';
  let quote = '';
  let escaped = false;
  let started = false;
  for (const char of input) {
    if (escaped) { token += char; escaped = false; started = true; }
    else if (char === '\\' && quote !== "'") { escaped = true; started = true; }
    else if (quote) { if (char === quote) quote = ''; else token += char; }
    else if (char === '"' || char === "'") { quote = char; started = true; }
    else if (/\s/.test(char)) { if (started) { tokens.push(token); token = ''; started = false; } }
    else { token += char; started = true; }
  }
  if (quote || escaped) return null;
  if (started) tokens.push(token);
  return tokens;
}

/** Deliberately fictional workstation data, shared by all system commands. */
export const DEMO_SYSTEM = {
  hostname: 'nerdos',
  os: 'NixOS 26.05 x86_64 · NerdOS',
  host: 'NerdOS Workstation (demo)',
  kernel: '6.18.57',
  uptime: '42 mins (demo session)',
  packages: '2148 (nix), 12 (flatpak)',
  shell: 'fish 4.3',
  wm: 'Hyprland (Wayland)',
  wmTheme: 'NerdOS · Quickshell',
  terminal: 'Kitty',
  cpu: 'AMD Ryzen 9 7950X (32) @ 5.70 GHz',
  gpu: 'AMD Radeon RX 7800 XT · 16 GiB',
  memory: '3.24 GiB / 31.19 GiB (10%)',
  disk: '64.2 GiB / 953.9 GiB (7%) · ext4',
  theme: 'NerdOS',
  font: 'JetBrains Mono · 12 pt',
} as const;

export const NERDOS_LOGO_COLORED = "   $1.################.     $2///$1.################.\n$1==#######################$2///$1####################==\n  $1####            ######$2///$1#####            ####\n  $1####            #### $2///  $1####            ####\n  $1####.          .####$2//    $1####.          .####\n  $1'##################'      '##################'\n    $1'##############'          '##############'";

export const NERDOS_LOGO = NERDOS_LOGO_COLORED.replace(/\$[12]/g, '');

export const SYSTEM_DETAILS = [
  ['OS', DEMO_SYSTEM.os],
  ['Host', DEMO_SYSTEM.host],
  ['Kernel', `${DEMO_SYSTEM.kernel} (sample)`],
  ['Uptime', DEMO_SYSTEM.uptime],
  ['Packages', DEMO_SYSTEM.packages],
  ['Shell', DEMO_SYSTEM.shell],
  ['WM', DEMO_SYSTEM.wm],
  ['WM Theme', DEMO_SYSTEM.wmTheme],
  ['Terminal', DEMO_SYSTEM.terminal],
  ['CPU', DEMO_SYSTEM.cpu],
  ['GPU', DEMO_SYSTEM.gpu],
  ['Memory', DEMO_SYSTEM.memory],
  ['Disk (/)', DEMO_SYSTEM.disk],
  ['Theme', DEMO_SYSTEM.theme],
  ['Font', DEMO_SYSTEM.font],
] as const;

export const SYSTEM_INFO = `guest@${DEMO_SYSTEM.hostname}
${'─'.repeat(30)}
${SYSTEM_DETAILS.map(([label, value]) => `${label.padEnd(10)} ${value}`).join('\n')}

Demo system information · sample hardware, packages, and kernel.`;

const COMMANDS = ['help', 'fastfetch', 'neofetch', 'ls', 'cd', 'pwd', 'cat', 'date', 'whoami', 'hostname', 'uptime', 'free', 'df', 'uname', 'echo', 'clear', 'history', 'nerd', 'exit'];
const APP_COMMANDS = ['settings', 'files', 'notes', 'welcome', 'shortcuts', 'usage'];

type ShellWord = { value: string; start: number; end: number };

/** Tolerates an unfinished quote while completing a literal shell word. */
function completionWords(input: string): ShellWord[] {
  const words: ShellWord[] = [];
  let value = '';
  let start = -1;
  let quote = '';
  let escaped = false;
  for (let i = 0; i < input.length; i++) {
    const char = input[i];
    if (start < 0 && /\s/.test(char)) continue;
    if (start < 0) start = i;
    if (escaped) { value += char; escaped = false; }
    else if (char === '\\' && quote !== "'") escaped = true;
    else if (quote) { if (char === quote) quote = ''; else value += char; }
    else if (char === '"' || char === "'") quote = char;
    else if (/\s/.test(char)) { words.push({ value, start, end: i }); value = ''; start = -1; }
    else value += char;
  }
  if (start >= 0) words.push({ value, start, end: input.length });
  return words;
}

export interface CompletionResult {
  input: string;
  cursor: number;
  candidates: string[];
}

/** Only completes names from our virtual filesystem; never accesses the host. */
export function completeInput(input: string, cwd = HOME_PATH, cursor = input.length): CompletionResult {
  const unchanged = { input, cursor, candidates: [] };
  const words = completionWords(input);
  const activeIndex = words.findIndex((word) => word.start <= cursor && cursor <= word.end);
  const active = activeIndex >= 0 ? words[activeIndex] : { start: cursor, end: cursor, value: '' };
  const wordIndex = activeIndex >= 0 ? activeIndex : words.filter((word) => word.end < cursor).length;
  const rawPrefix = input.slice(active.start, cursor);
  const prefix = completionWords(rawPrefix)[0]?.value || '';
  let candidates: string[];
  if (wordIndex === 0) candidates = COMMANDS.filter((name) => name.startsWith(prefix));
  else if (words[0]?.value === 'nerd' && wordIndex === 1) candidates = APP_COMMANDS.filter((name) => name.startsWith(prefix));
  else if (['cd', 'ls', 'cat'].includes(words[0]?.value)) {
    if (prefix.startsWith('-')) return unchanged;
    const pathPrefix = prefix === '~' ? '~/' : prefix;
    const slash = pathPrefix.lastIndexOf('/');
    const parentPrefix = slash < 0 ? '' : pathPrefix.slice(0, slash + 1);
    const namePrefix = pathPrefix.slice(slash + 1);
    const path = resolvePath(parentPrefix || '.', cwd);
    const directory = Object.hasOwn(FILE_SYSTEM, path) ? FILE_SYSTEM[path] : [];
    candidates = directory.filter((file) => file.name.startsWith(namePrefix) && (words[0].value !== 'cd' || file.kind === 'folder'))
      .map((file) => `${parentPrefix}${file.name}${file.kind === 'folder' ? '/' : ''}`);
  } else return unchanged;
  if (!candidates.length) return unchanged;
  let completion = candidates[0];
  for (const candidate of candidates.slice(1)) {
    while (!candidate.startsWith(completion)) completion = completion.slice(0, -1);
  }
  if (candidates.length > 1 && completion.length <= prefix.length) return { ...unchanged, candidates };
  const quote = rawPrefix[0] === "'" ? "'" : rawPrefix[0] === '"' || /\s/.test(completion) ? '"' : '';
  const escaped = quote === '"' ? completion.replace(/["\\]/g, '\\$&') : completion;
  const replacement = `${quote}${escaped}${quote}`;
  const complete = candidates.length === 1 && !completion.endsWith('/');
  const suffix = input.slice(active.end);
  const space = complete && !/^\s/.test(suffix) ? ' ' : '';
  const next = input.slice(0, active.start) + replacement + space + suffix;
  const nextCursor = active.start + replacement.length + space.length - (!complete && quote ? 1 : 0);
  return { input: next, cursor: nextCursor, candidates: candidates.length > 1 ? candidates : [] };
}

export interface CommandResult {
  output: string;
  cwd: string;
  clear?: boolean;
  openApp?: AppId;
  presentation?: 'fastfetch' | 'history';
}

/** Interprets a fixed set of preview commands. Never executes shell code. */
export function runCommand(input: string, cwd = HOME_PATH, now = new Date()): CommandResult {
  const base = { output: '', cwd };
  const tokens = tokenize(input);
  if (!tokens) return { ...base, output: 'Unclosed quote or escape. Finish the command and try again.' };
  if (!tokens.length) return base;
  const [command, ...args] = tokens;
  const result = (output: string): CommandResult => ({ ...base, output });
  switch (command) {
    case 'help': return result(`A small terminal. Plenty to explore.

  fastfetch          A look at your desktop
  ls [path]          List sample files and folders
  cd [path]          Navigate the sample filesystem
  pwd                Show your current location
  cat <file>         Read a sample text file
  date               Show your local date and time
  whoami / hostname  Your preview user and workstation
  uptime             Demo session uptime
  free [-h]          Sample memory usage
  df [-h]            Sample disk usage
  uname [-a/-r/-m]   Sample NerdOS kernel information
  history            Show this terminal’s command history
  echo <text>        Print text
  clear              Clear the terminal
  nerd --help       Open desktop apps

Tab completion · ↑ / ↓ history · Ctrl + C cancel · Ctrl + L clear
This terminal is simulated. Commands never run on your device.`);
    case 'clear': return { ...base, clear: true };
    case 'fastfetch':
    case 'neofetch': return { ...result(SYSTEM_INFO), presentation: 'fastfetch' };
    case 'history': return { ...base, presentation: 'history' };
    case 'hostname': return result(DEMO_SYSTEM.hostname);
    case 'uptime': return result('up 42 min, 1 user, load average: 0.21, 0.18, 0.16\nDemo session · simulated uptime and load');
    case 'free': return result('               total        used        free      shared  buff/cache   available\nMem:          31.19Gi      3.24Gi     24.70Gi       128Mi      3.25Gi     27.30Gi\nSwap:          8.00Gi          0B      8.00Gi\n\nDemo system information · sample memory usage');
    case 'df': return result('Filesystem      Size   Used  Avail Use% Mounted on\n/dev/nvme0n1p3  954G    64G   890G   7% /\n/dev/nvme0n1p2  974M   312M   595M  35% /boot\n/dev/nvme0n1p1  599M    19M   580M   4% /boot/efi\n\nDemo system information · sample storage usage');
    case 'pwd': return result(cwd);
    case 'whoami': return result('guest');
    case 'date': return result(now.toLocaleString(undefined, { dateStyle: 'full', timeStyle: 'long' }));
    case 'uname': {
      if (!args.length || args.every((arg) => arg === '-s')) return result('Linux');
      if (args.includes('-a')) return result(`Linux ${DEMO_SYSTEM.hostname} ${DEMO_SYSTEM.kernel} #1 SMP PREEMPT_DYNAMIC x86_64 GNU/Linux (demo fixture)`);
      if (args.some((arg) => !['-s', '-r', '-m', '-n', '-o'].includes(arg))) return result('uname: try -a, -s, -r, -m, -n, or -o. Information is simulated.');
      const fields: Record<string, string> = { '-s': 'Linux', '-r': DEMO_SYSTEM.kernel, '-m': 'x86_64', '-n': DEMO_SYSTEM.hostname, '-o': 'GNU/Linux' };
      return result(args.map((arg) => fields[arg]).join(' '));
    }
    case 'echo': return result(args.join(' '));
    case 'cd': {
      if (args.length > 1) return result('cd: expected one path. Put paths with spaces in quotes.');
      const path = resolvePath(args[0] || '~', cwd);
      return Object.hasOwn(FILE_SYSTEM, path) ? { ...base, cwd: path } : result(`cd: ${args[0]}: no such sample directory`);
    }
    case 'ls': {
      const pathArgs = args.filter((arg) => !arg.startsWith('-'));
      const unsupported = args.find((arg) => arg.startsWith('-') && !/^-[lah]+$/.test(arg));
      if (unsupported) return result(`ls: unsupported option ${unsupported}. Try ls or ls -la.`);
      if (pathArgs.length > 1) return result('ls: expected at most one path. Put paths with spaces in quotes.');
      const path = resolvePath(pathArgs[0] || '.', cwd);
      if (!Object.hasOwn(FILE_SYSTEM, path)) return result(`ls: ${pathArgs[0]}: no such sample directory`);
      return result(FILE_SYSTEM[path].map((file) => `${file.name}${file.kind === 'folder' ? '/' : ''}`).join('   ') || '(empty folder)');
    }
    case 'cat': {
      if (!args.length) return result('Usage: cat <file>  ·  Try cat ~/Welcome.txt');
      return result(args.map((name) => {
        const path = resolvePath(name, cwd);
        if (Object.hasOwn(FILE_SYSTEM, path)) return `cat: ${name}: is a directory`;
        const slash = path.lastIndexOf('/');
        const parent = path.slice(0, slash) || '/';
        const file = Object.hasOwn(FILE_SYSTEM, parent) ? FILE_SYSTEM[parent].find((entry) => entry.name === path.slice(slash + 1)) : undefined;
        if (!file) return `cat: ${name}: no such sample file`;
        if (file.kind === 'note') return 'Your notes live in Omawrite. Open them with: nerd notes';
        if (file.kind === 'image') return 'This is an image. View it in Files with: nerd files';
        return file.content || '';
      }).join('\n'));
    }
    case 'nerd': {
      const appNames: Record<string, AppId> = { settings: 'settings', files: 'files', notes: 'notes', welcome: 'welcome', shortcuts: 'shortcuts', usage: 'usage' };
      if (args.length === 1 && Object.hasOwn(appNames, args[0])) return { ...base, output: `Opening ${args[0]}…`, openApp: appNames[args[0]] };
      return result('NerdOS desktop commands\n\n  nerd settings    Personalize your desktop\n  nerd files       Browse sample files\n  nerd notes       Open Omawrite\n  nerd welcome     About NerdOS\n  nerd shortcuts   Keyboard shortcuts\n  nerd usage       Codex & Claude subscription usage');
    }
    case 'sudo':
    case 'apt':
    case 'pacman':
    case 'nix':
    case 'nixos-rebuild':
    case 'flatpak':
    case 'rm':
    case 'curl':
    case 'wget':
    case 'sh':
    case 'bash': return result(`${command}: this is a simulated terminal. It cannot install software, access your device, or run scripts. Type help for supported commands.`);
    case 'exit': return result('Use the window’s close button to leave the terminal.');
    default: return result(`${command}: command not found in this preview. Type help to see what you can try.`);
  }
}
