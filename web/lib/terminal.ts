import type { AppId } from './types';

export const HOME_PATH = '/home/guest';
export const README_CONTENT = `Welcome to CybexOS
==================

Cybex Opinionated System is a Hyprland desktop built around
a fast keyboard-first workflow, Quickshell, and a coherent theme.

This browser experience recreates the feel of the desktop.
It is an interactive preview, not a running Linux machine.

Things to try
------------
• Open the launcher and find an app.
• Switch workspaces from the top bar.
• Change your theme in Settings.
• Write something in Omawrite. Notes stay in this browser.
• Type help in the terminal to explore supported commands.

Source: https://github.com/DigitalPals/CybexOS
`;

export const SHORTCUTS_CONTENT = `CybexOS browser shortcuts
========================

Alt + Space        Open the launcher
Alt + 1 / 2 / 3 / 4 / 5 Switch workspace
Alt + Enter        Open terminal
Alt + K            Open keyboard shortcuts
Escape             Close the launcher or an open panel

Terminal
--------
↑ / ↓              Browse command history
Ctrl + L           Clear terminal output

The real desktop uses Super-based shortcuts. This preview
uses Alt so your operating system keeps its own key bindings.
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
    { name: 'README.md', kind: 'text', description: 'Markdown document', content: '# Make it yours\n\nCybexOS is open source.\n\nExplore the desktop, image builder, and documentation at:\nhttps://github.com/DigitalPals/CybexOS\n\nThis is a sample folder in the browser preview.\n' },
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

export const SYSTEM_INFO = `       ▄████████▄       guest@cybexos
     ▄██▀      ▀██▄     ─────────────────────────────
    ███                 OS        CybexOS · browser preview
    ███                 Desktop   Hyprland experience
    ███                 Shell     Quickshell
     ▀██▄      ▄██▀     Terminal  Kitty experience
       ▀████████▀       Theme     Yours to make

    A little different. Entirely yours.`;

export interface CommandResult {
  output: string;
  cwd: string;
  clear?: boolean;
  openApp?: AppId;
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
  whoami             Your preview user
  uname [-a]         About this environment
  echo <text>        Print text
  clear              Clear the terminal
  cybex --help       Open desktop apps

↑ / ↓ command history · Ctrl + L to clear
This terminal is simulated. Commands never run on your device.`);
    case 'clear': return { ...base, clear: true };
    case 'fastfetch':
    case 'neofetch': return result(SYSTEM_INFO);
    case 'pwd': return result(cwd);
    case 'whoami': return result('guest');
    case 'date': return result(now.toLocaleString(undefined, { dateStyle: 'full', timeStyle: 'long' }));
    case 'uname': return result(args.includes('-a') ? 'CybexOS browser preview · simulated desktop · no Linux kernel' : 'CybexOS browser preview');
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
        if (file.kind === 'note') return 'Your notes live in Omawrite. Open them with: cybex notes';
        if (file.kind === 'image') return 'This is an image. View it in Files with: cybex files';
        return file.content || '';
      }).join('\n'));
    }
    case 'cybex': {
      const appNames: Record<string, AppId> = { settings: 'settings', files: 'files', notes: 'notes', welcome: 'welcome', shortcuts: 'shortcuts' };
      if (args.length === 1 && Object.hasOwn(appNames, args[0])) return { ...base, output: `Opening ${args[0]}…`, openApp: appNames[args[0]] };
      return result('CybexOS desktop commands\n\n  cybex settings    Personalize your desktop\n  cybex files       Browse sample files\n  cybex notes       Open Omawrite\n  cybex welcome     About CybexOS\n  cybex shortcuts   Keyboard shortcuts');
    }
    case 'sudo':
    case 'apt':
    case 'pacman':
    case 'rm':
    case 'curl':
    case 'wget':
    case 'sh':
    case 'bash': return result(`${command}: this is a simulated terminal. It cannot install software, access your device, or run scripts. Type help for supported commands.`);
    case 'exit': return result('Use the window’s close button to leave the terminal.');
    default: return result(`${command}: command not found in this preview. Type help to see what you can try.`);
  }
}
