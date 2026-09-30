import { describe, expect, it } from 'vitest';
import { displayPath, HOME_PATH, README_CONTENT, resolvePath, runCommand } from '../lib/terminal';

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
