import { describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { TerminalApp } from '../components/TerminalApp';

describe('terminal interactions', () => {
  it('does not submit a pending command when the desktop Alt+Enter shortcut is pressed', async () => {
    const user = userEvent.setup();
    const openApp = vi.fn();
    render(<TerminalApp openApp={openApp} notify={vi.fn()} />);
    const input = screen.getByRole('textbox', { name: 'Terminal command' });
    await user.type(input, 'cybex settings');
    await user.keyboard('{Alt>}{Enter}{/Alt}');
    expect(input).toHaveValue('cybex settings');
    expect(openApp).not.toHaveBeenCalled();
    expect(screen.getByRole('log', { name: 'Terminal output' })).not.toHaveTextContent('Opening settings…');
  });
});

describe('improved terminal', () => {
  it('shows a readable Cybex OS overview for fastfetch aliases and options', async () => {
    const user = userEvent.setup();
    render(<TerminalApp openApp={vi.fn()} notify={vi.fn()} />);
    expect(screen.getByRole('region', { name: 'Cybex OS system overview' })).toHaveTextContent('NixOS 26.05 x86_64');
    expect(screen.getByRole('region', { name: 'Cybex OS system overview' })).toHaveTextContent('Hyprland (Wayland)');
    const input = screen.getByRole('textbox', { name: 'Terminal command' });
    await user.type(input, '  neofetch --logo cybexos  {Enter}');
    const overviews = screen.getAllByRole('region', { name: 'Cybex OS system overview' });
    expect(overviews).toHaveLength(2);
    expect(overviews[1]).toHaveTextContent('Demo system information');
    expect(overviews[1]).toHaveTextContent('Kitty');
  });

  it('restores a draft after browsing history and leaves it intact on ArrowDown at the live prompt', async () => {
    const user = userEvent.setup();
    render(<TerminalApp openApp={vi.fn()} notify={vi.fn()} />);
    const input = screen.getByRole('textbox', { name: 'Terminal command' });
    await user.type(input, 'pwd{Enter}whoami{Enter}echo unfinished');
    await user.keyboard('{ArrowUp}');
    expect(input).toHaveValue('whoami');
    await user.keyboard('{ArrowUp}');
    expect(input).toHaveValue('pwd');
    await user.keyboard('{ArrowDown}{ArrowDown}');
    expect(input).toHaveValue('echo unfinished');
    await user.keyboard('{ArrowDown}');
    expect(input).toHaveValue('echo unfinished');
  });

  it('completes commands and quoted files and executes the completed path', async () => {
    const user = userEvent.setup();
    render(<TerminalApp openApp={vi.fn()} notify={vi.fn()} />);
    const input = screen.getByRole('textbox', { name: 'Terminal command' });
    await user.type(input, 'fas');
    await user.keyboard('{Tab}');
    expect(input).toHaveValue('fastfetch ');
    expect(input).toHaveFocus();
    await user.clear(input);
    await user.type(input, 'cat "Documents/My');
    await user.keyboard('{Tab}');
    expect(input).toHaveValue('cat "Documents/My notes.md" ');
    await user.keyboard('{Enter}');
    expect(screen.getByRole('log')).toHaveTextContent('Your notes live in Omawrite');
    await user.type(input, 'c');
    await user.keyboard('{Tab}');
    expect(screen.getByRole('status', { name: 'Completion suggestions' })).toHaveTextContent('clear');
    await user.clear(input);
    await user.type(input, 'c');
    await user.keyboard('{Tab}');
    expect(screen.getByRole('status', { name: 'Completion suggestions' })).toHaveTextContent('cybex');
  });

  it('cancels drafts, clears the line, and clears output without executing a desktop intent', async () => {
    const user = userEvent.setup();
    const openApp = vi.fn();
    render(<TerminalApp openApp={openApp} notify={vi.fn()} />);
    const input = screen.getByRole('textbox', { name: 'Terminal command' });
    await user.type(input, 'cybex settings');
    await user.keyboard('{Control>}c{/Control}');
    expect(input).toHaveValue('');
    expect(openApp).not.toHaveBeenCalled();
    expect(screen.getByRole('log')).toHaveTextContent('cybex settings^C');
    await user.type(input, 'echo draft');
    await user.keyboard('{Control>}u{/Control}');
    expect(input).toHaveValue('');
    await user.type(input, 'keep this');
    await user.keyboard('{Control>}l{/Control}');
    expect(screen.getByRole('log')).toBeEmptyDOMElement();
    expect(input).toHaveValue('keep this');
  });

  it('does not intercept desktop Alt navigation or Meta shortcuts while input is focused', async () => {
    const user = userEvent.setup();
    render(<TerminalApp openApp={vi.fn()} notify={vi.fn()} />);
    const input = screen.getByRole('textbox', { name: 'Terminal command' });
    await user.type(input, 'pwd{Enter}echo draft');
    await user.keyboard('{Alt>}{ArrowUp}{/Alt}');
    expect(input).toHaveValue('echo draft');
    await user.keyboard('{Alt>}{Shift>}{ArrowDown}{/Shift}{/Alt}');
    expect(input).toHaveValue('echo draft');
    await user.keyboard('{Meta>}{ArrowUp}{/Meta}');
    expect(input).toHaveValue('echo draft');
  });

  it('shows submitted commands in history while excluding cancelled drafts', async () => {
    const user = userEvent.setup();
    render(<TerminalApp openApp={vi.fn()} notify={vi.fn()} />);
    const input = screen.getByRole('textbox', { name: 'Terminal command' });
    await user.type(input, 'pwd{Enter}whoami{Enter}');
    await user.type(input, 'never-run');
    await user.keyboard('{Control>}c{/Control}');
    await user.type(input, 'clear{Enter}history{Enter}');
    const output = screen.getByRole('log');
    expect(output).toHaveTextContent('1 pwd');
    expect(output).toHaveTextContent('2 whoami');
    expect(output).toHaveTextContent('3 clear');
    expect(output).toHaveTextContent('4 history');
    expect(output).not.toHaveTextContent('never-run');
  });
});
