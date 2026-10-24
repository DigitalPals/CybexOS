import { describe, expect, it } from 'vitest';
import { completeInput, DEMO_SYSTEM, displayPath, HOME_PATH, README_CONTENT, resolvePath, runCommand, SYSTEM_INFO } from '../lib/terminal';

describe('simulated terminal', () => {
  it('navigates relative, absolute, and home paths without leaving the sample filesystem', () => {
    expect(runCommand('cd Documents').cwd).toBe(`${HOME_PATH}/Documents`);
    expect(runCommand('cd ..', `${HOME_PATH}/Documents`).cwd).toBe(HOME_PATH);
    expect(runCommand('cd ~/Pictures', '/').cwd).toBe(`${HOME_PATH}/Pictures`);
    expect(runCommand('cd /etc').cwd).toBe(HOME_PATH);
    expect(runCommand('cd /etc').output).toContain('no such sample directory');
    expect(resolvePath('../../../../', HOME_PATH)).toBe('/');
    expect(displayPath('/home/guesthouse')).toBe('/home/guesthouse');
  });

  it('reads text fixtures, supports quoted paths, and explains non-text fixtures', () => {
    expect(runCommand('cat ~/Welcome.txt').output).toBe(README_CONTENT);
    expect(runCommand('cat "Documents/My notes.md"').output).toContain('Omawrite');
    expect(runCommand('cat Documents/My\\ notes.md').output).toContain('Omawrite');
    expect(runCommand('cat Pictures/moon-mountains.jpg').output).toContain('image');
    expect(runCommand('cat Documents').output).toContain('is a directory');
    expect(runCommand('cat missing.txt').output).toContain('no such sample file');
  });

  it('rejects prototype names as directories or app commands', () => {
    expect(runCommand('cd __proto__').output).toContain('no such sample directory');
    expect(runCommand('ls constructor').output).toContain('no such sample directory');
    expect(runCommand('cybex constructor').openApp).toBeUndefined();
  });

  it('treats shell syntax as data and never executes commands or expands variables', () => {
    expect(runCommand('echo $(whoami)').output).toBe('$(whoami)');
    expect(runCommand('echo `whoami`').output).toBe('`whoami`');
    expect(runCommand('echo $HOME').output).toBe('$HOME');
    expect(runCommand('echo hello; rm -rf /').output).toBe('hello; rm -rf /');
    expect(runCommand('bash -c whoami').output).toContain('simulated terminal');
    expect(runCommand('rm ~/Welcome.txt').output).toContain('simulated terminal');
    expect(runCommand('cat ~/Welcome.txt').output).toBe(README_CONTENT);
  });

  it('handles malformed input, empty commands, and empty folders', () => {
    expect(runCommand('cat "unfinished').output).toContain('Unclosed quote');
    expect(runCommand('  ').output).toBe('');
    expect(runCommand('ls Downloads').output).toBe('(empty folder)');
    expect(runCommand('ls -la').output).toContain('Documents/');
    expect(runCommand('ls --unsupported').output).toContain('unsupported option');
  });

  it('returns explicit desktop intents without host side effects', () => {
    expect(runCommand('cybex settings').openApp).toBe('settings');
    expect(runCommand('cybex notes').openApp).toBe('notes');
    expect(runCommand('clear').clear).toBe(true);
    expect(runCommand('whoami').output).toBe('guest');
    expect(runCommand('help').output).toContain('never run on your device');
    expect(runCommand('sudo reboot').output).toContain('simulated');
  });
});


describe('Cybex OS system commands', () => {
  it('renders the Cybex OS overview based on the parsed command, including quotes, whitespace, and options', () => {
    for (const command of ['fastfetch', '  fastfetch  ', 'fastfetch --logo cybexos', 'neofetch', '"fastfetch"']) {
      const result = runCommand(command);
      expect(result.presentation).toBe('fastfetch');
      expect(result.output).toBe(SYSTEM_INFO);
      expect(result.output).toContain('NixOS 26.05 x86_64');
      expect(result.output).toContain('Hyprland (Wayland)');
      expect(result.output).toContain('Demo system information');
    }
    expect(runCommand('echo fastfetch').presentation).toBeUndefined();
    expect(runCommand('fastfetch; uname').presentation).toBeUndefined();
    expect(runCommand('fastfetch "unfinished').presentation).toBeUndefined();
  });

  it('keeps simulated hardware and kernel output consistent with the overview', () => {
    expect(runCommand('uname').output).toBe('Linux');
    expect(runCommand('uname -r').output).toBe(DEMO_SYSTEM.kernel);
    expect(runCommand('uname -a').output).toContain(DEMO_SYSTEM.kernel);
    expect(runCommand('uname -a').output).toContain('demo fixture');
    expect(runCommand('uname -m').output).toBe('x86_64');
    expect(runCommand('hostname').output).toBe(DEMO_SYSTEM.hostname);
    expect(runCommand('uptime').output).toContain('42 min');
    expect(runCommand('free -h').output).toContain('3.24Gi');
    expect(runCommand('df -h').output).toContain('Demo system information');
    expect(runCommand('nix shell nixpkgs#fish').output).toContain('simulated terminal');
  });
});

describe('terminal completion', () => {
  it('completes commands and app intents and exposes ambiguous candidates', () => {
    expect(completeInput('fas').input).toBe('fastfetch ');
    expect(completeInput('cybex set').input).toBe('cybex settings ');
    expect(completeInput('c').candidates).toEqual(expect.arrayContaining(['cat', 'cd', 'clear']));
    expect(completeInput('c').candidates).toContain('cybex');
    expect(completeInput('c').input).toBe('c');
    expect(completeInput('unsupported /etc').input).toBe('unsupported /etc');
  });

  it('completes home, relative, and absolute virtual paths with directory-aware filtering', () => {
    expect(completeInput('cd Doc').input).toBe('cd Documents/');
    expect(completeInput('cat ~/Wel').input).toBe('cat ~/Welcome.txt ');
    expect(completeInput('cat /home/guest/Code/R').input).toBe('cat /home/guest/Code/README.md ');
    expect(completeInput('cat Short', `${HOME_PATH}/Documents`).input).toBe('cat Shortcuts.txt ');
    expect(completeInput('cd Wel').input).toBe('cd Wel');
    expect(completeInput('ls /etc/pass').input).toBe('ls /etc/pass');
    expect(completeInput('cat __proto__/').candidates).toEqual([]);
  });

  it('produces executable literal paths containing spaces from quoted and escaped prefixes', () => {
    for (const input of ['cat Documents/My', 'cat "Documents/My', "cat 'Documents/My", 'cat Documents/My\\ n']) {
      const completion = completeInput(input);
      expect(runCommand(completion.input).output).toContain('Your notes live in Omawrite');
    }
    const quotedDirectory = completeInput('cat "Doc');
    expect(quotedDirectory.input).toBe('cat "Documents/"');
    expect(quotedDirectory.cursor).toBe(quotedDirectory.input.length - 1);
    const name = quotedDirectory.input.slice(0, quotedDirectory.cursor) + 'My' + quotedDirectory.input.slice(quotedDirectory.cursor);
    const completed = completeInput(name, HOME_PATH, quotedDirectory.cursor + 2);
    expect(completed.input).toBe('cat "Documents/My notes.md" ');
    expect(runCommand(completed.input).output).toContain('Omawrite');
  });

  it('completes at the caret and preserves subsequent arguments', () => {
    const result = completeInput('cat Wel Documents/Shortcuts.txt', HOME_PATH, 7);
    expect(result.input).toBe('cat Welcome.txt Documents/Shortcuts.txt');
    expect(runCommand(result.input).output).toContain('Cybex OS browser shortcuts');
  });
});
