import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import Desktop from '../components/Desktop';

type User = ReturnType<typeof userEvent.setup>;

beforeEach(() => {
  localStorage.clear();
  vi.stubGlobal('innerWidth', 1440);
  vi.stubGlobal('innerHeight', 900);
});
afterEach(() => vi.unstubAllGlobals());

function rectangle(window: HTMLElement) {
  return {
    left: Number.parseFloat(window.style.left),
    top: Number.parseFloat(window.style.top),
    width: Number.parseFloat(window.style.width),
    height: Number.parseFloat(window.style.height),
  };
}

function expectSeparated(windows: HTMLElement[]) {
  for (const window of windows) {
    expect(window).toHaveAttribute('data-layout', 'tiled');
    const bounds = rectangle(window);
    expect(bounds.left).toBeGreaterThanOrEqual(0);
    expect(bounds.top).toBeGreaterThan(36);
    expect(bounds.width).toBeGreaterThan(0);
    expect(bounds.height).toBeGreaterThan(0);
    expect(bounds.left + bounds.width).toBeLessThanOrEqual(innerWidth);
  }
  windows.forEach((window, index) => {
    const a = rectangle(window);
    windows.slice(index + 1).forEach(other => {
      const b = rectangle(other);
      expect(a.left + a.width < b.left || b.left + b.width < a.left || a.top + a.height < b.top || b.top + b.height < a.top).toBe(true);
    });
  });
}

async function startDesktop(user: User) {
  render(<Desktop />);
  await user.click(screen.getByRole('button', { name: 'Close Welcome to NerdOS' }));
  await user.keyboard('{Alt>}{Enter}{/Alt}');
  const terminal = screen.getByRole('region', { name: 'Kitty window' });
  const command = within(terminal).getByRole('textbox', { name: 'Terminal command' });
  await waitFor(() => expect(command).toHaveFocus());
  return { terminal, command };
}

async function openFiles(user: User) {
  await user.click(screen.getByRole('button', { name: 'Open app launcher' }));
  await user.type(screen.getByRole('textbox', { name: 'Search applications' }), 'files{Enter}');
  const files = screen.getByRole('region', { name: 'Files window' });
  await waitFor(() => expect(within(files).getByRole('textbox', { name: 'Search this folder' })).toHaveFocus());
  return files;
}

async function openNotes(user: User) {
  await user.click(screen.getByRole('button', { name: 'Open notes' }));
  const notes = screen.getByRole('region', { name: 'Omawrite window' });
  const editor = within(notes).getByRole('textbox', { name: 'Note content' });
  await waitFor(() => expect(editor).toHaveFocus());
  return { notes, editor };
}

describe('Hyprland-style desktop interactions', () => {
  it('tiles multiple apps without overlap and keeps their positions and drafts when focus changes', async () => {
    const user = userEvent.setup();
    const { terminal, command } = await startDesktop(user);
    await user.type(command, 'echo unfinished');
    const files = await openFiles(user);
    const { notes, editor } = await openNotes(user);
    await user.clear(editor);
    await user.type(editor, 'A separate note.');
    const windows = [terminal, files, notes];
    expectSeparated(windows);
    const positions = windows.map(rectangle);

    await user.click(command);
    await user.keyboard(' draft');

    expect(terminal).toHaveClass('active');
    expect(command).toHaveFocus();
    expect(command).toHaveValue('echo unfinished draft');
    expect(editor).toHaveValue('A separate note.');
    expect(windows.map(rectangle)).toEqual(positions);
    expect(within(terminal).getByRole('textbox', { name: 'Terminal command' })).toBe(command);
  });

  it('reflows tiles when apps float, minimize, restore, and close', async () => {
    const user = userEvent.setup();
    const { terminal, command } = await startDesktop(user);
    await user.type(command, 'echo keep me');
    const single = rectangle(terminal);
    const files = await openFiles(user);
    const split = rectangle(terminal);
    expect(split.width).toBeLessThan(single.width);
    expectSeparated([terminal, files]);

    await user.click(within(files).getByRole('button', { name: 'Float Files' }));
    expect(files).toHaveAttribute('data-layout', 'floating');
    expect(rectangle(terminal)).toEqual(single);
    await user.click(within(files).getByRole('button', { name: 'Tile Files' }));
    expect(rectangle(terminal)).toEqual(split);
    expectSeparated([terminal, files]);

    await user.click(within(files).getByRole('button', { name: 'Minimize Files' }));
    expect(screen.queryByRole('region', { name: 'Files window' })).not.toBeInTheDocument();
    expect(rectangle(terminal)).toEqual(single);
    await user.click(screen.getByRole('button', { name: 'Restore Files' }));
    expect(rectangle(terminal)).toEqual(split);
    expectSeparated([terminal, files]);
    await user.click(within(files).getByRole('button', { name: 'Close Files' }));
    expect(rectangle(terminal)).toEqual(single);
    expect(command).toHaveValue('echo keep me');
  });

  it('focuses and swaps neighboring tiles without losing the focused editor', async () => {
    const user = userEvent.setup();
    const { terminal, command } = await startDesktop(user);
    const { notes, editor } = await openNotes(user);
    await user.clear(editor);
    await user.type(editor, 'Keep writing');
    const terminalPosition = rectangle(terminal);
    const notesPosition = rectangle(notes);
    expect(terminalPosition.left).toBeLessThan(notesPosition.left);

    await user.click(command);
    await user.keyboard('{Alt>}{ArrowRight}{/Alt}');
    await waitFor(() => expect(editor).toHaveFocus());
    expect(notes).toHaveClass('active');
    await user.keyboard('{Alt>}{Shift>}{ArrowLeft}{/Shift}{/Alt}');
    expect(rectangle(notes)).toEqual(terminalPosition);
    expect(rectangle(terminal)).toEqual(notesPosition);
    expect(editor).toHaveFocus();
    await user.keyboard(' after swapping');
    expect(editor).toHaveValue('Keep writing after swapping');
    expect(command).toHaveValue('');

    await user.click(within(notes).getByRole('button', { name: 'Swap Omawrite with next tile' }));
    expect(rectangle(terminal)).toEqual(terminalPosition);
    expect(rectangle(notes)).toEqual(notesPosition);
  });

  it('returns typing focus to the remaining app when the focused window minimizes, closes, or moves away', async () => {
    const user = userEvent.setup();
    const { terminal, command } = await startDesktop(user);
    await user.type(command, 'echo continue');
    const { notes, editor } = await openNotes(user);
    await user.clear(editor);
    await user.type(editor, 'Leave this note unchanged.');

    await user.click(within(notes).getByRole('button', { name: 'Minimize Omawrite' }));
    await waitFor(() => expect(command).toHaveFocus());
    expect(terminal).toHaveClass('active');
    await user.keyboard(' after minimizing');

    await user.click(screen.getByRole('button', { name: 'Restore Omawrite' }));
    await waitFor(() => expect(editor).toHaveFocus());
    await user.click(within(notes).getByRole('button', { name: 'Close Omawrite' }));
    await waitFor(() => expect(command).toHaveFocus());
    await user.keyboard(' after closing');

    const reopened = await openNotes(user);
    await user.selectOptions(within(reopened.notes).getByRole('combobox', { name: 'Move Omawrite to workspace' }), '2');
    await waitFor(() => expect(command).toHaveFocus());
    expect(screen.queryByRole('region', { name: 'Omawrite window' })).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Workspace 1' })).toHaveAttribute('aria-current', 'page');
    await user.keyboard(' after moving');

    expect(command).toHaveValue('echo continue after minimizing after closing after moving');
    expect(reopened.editor).toHaveValue('Leave this note unchanged.');
    expect(terminal).toHaveClass('active');
  });

  it('moves the active app to another workspace without following it or discarding its draft', async () => {
    const user = userEvent.setup();
    const { terminal, command } = await startDesktop(user);
    await user.type(command, 'echo on workspace three');
    const files = await openFiles(user);
    const split = rectangle(files);
    await user.click(command);
    fireEvent.keyDown(command, { key: '#', code: 'Digit3', altKey: true, shiftKey: true });

    expect(screen.getByRole('button', { name: 'Workspace 1' })).toHaveAttribute('aria-current', 'page');
    expect(screen.queryByRole('region', { name: 'Kitty window' })).not.toBeInTheDocument();
    expect(rectangle(files).width).toBeGreaterThan(split.width);
    await user.keyboard('{Alt>}3{/Alt}');
    expect(screen.getByRole('region', { name: 'Kitty window' })).toBe(terminal);
    expect(command).toHaveValue('echo on workspace three');
    expect(screen.queryByRole('region', { name: 'Files window' })).not.toBeInTheDocument();
    expect(terminal).toHaveAttribute('data-layout', 'tiled');
  });

  it('zooms and restores a tile, then exits zoom when another app is focused', async () => {
    const user = userEvent.setup();
    const { terminal, command } = await startDesktop(user);
    const files = await openFiles(user);
    const positions = [terminal, files].map(rectangle);
    await user.click(command);
    await user.type(command, 'echo zoom draft');
    await user.keyboard('{Alt>}v{/Alt}');
    expect(terminal).toHaveAttribute('data-layout', 'floating');
    await user.keyboard('{Alt>}v{/Alt}');
    expect(terminal).toHaveAttribute('data-layout', 'tiled');
    expect([terminal, files].map(rectangle)).toEqual(positions);
    await user.keyboard('{Alt>}f{/Alt}');

    expect(terminal).toHaveClass('maximized');
    expect(screen.queryByRole('region', { name: 'Files window' })).not.toBeInTheDocument();
    await user.keyboard('{Alt>}f{/Alt}');
    expect(terminal).not.toHaveClass('maximized');
    expect([terminal, files].map(rectangle)).toEqual(positions);
    await user.keyboard('{Alt>}f{/Alt}');
    await user.click(screen.getByRole('button', { name: 'Focus Files' }));
    expect(terminal).not.toHaveClass('maximized');
    expect(files).toHaveClass('active');
    expectSeparated([terminal, files]);
    expect(command).toHaveValue('echo zoom draft');
  });

  it('keeps window shortcuts inactive while an overlay or lock screen owns input', async () => {
    const user = userEvent.setup();
    const { terminal, command } = await startDesktop(user);
    const { notes } = await openNotes(user);
    await user.click(command);
    const positions = [terminal, notes].map(rectangle);
    await user.click(screen.getByRole('button', { name: 'Open app launcher' }));
    const search = screen.getByRole('textbox', { name: 'Search applications' });
    await user.keyboard('{Alt>}v{/Alt}{Alt>}f{/Alt}{Alt>}{ArrowRight}{/Alt}{Alt>}{Shift>}3{/Shift}{/Alt}');
    expect(search).toHaveFocus();
    expect(terminal).toHaveAttribute('data-layout', 'tiled');
    expect(terminal).not.toHaveClass('maximized');
    expect(terminal).toHaveClass('active');
    expect([terminal, notes].map(rectangle)).toEqual(positions);
    expect(screen.getByRole('button', { name: 'Workspace 1' })).toHaveAttribute('aria-current', 'page');
    await user.keyboard('{Escape}');

    await user.click(screen.getByRole('button', { name: 'Open control panel' }));
    await user.click(screen.getByRole('button', { name: 'Lock demo' }));
    await user.keyboard('{Alt>}v{/Alt}{Alt>}f{/Alt}{Alt>}{Shift>}3{/Shift}{/Alt}');
    expect(screen.getByRole('button', { name: /Unlock demo/ })).toBeVisible();
    expect(terminal).toHaveAttribute('data-layout', 'tiled');
    expect(terminal).not.toHaveClass('maximized');
    await user.click(screen.getByRole('button', { name: /Unlock demo/ }));
    expect(screen.getByRole('region', { name: 'Kitty window' })).toBeVisible();
    expect([terminal, notes].map(rectangle)).toEqual(positions);
  });

  it('resizes the main split with the layout controls and keyboard, keeping ratios per workspace', async () => {
    const user = userEvent.setup();
    const { terminal } = await startDesktop(user);
    const files = await openFiles(user);
    const original = [terminal, files].map(rectangle);
    await user.click(screen.getByRole('button', { name: 'Tiling layout' }));
    fireEvent.change(screen.getByRole('slider', { name: 'Main tile width' }), { target: { value: '62' } });
    expect(rectangle(terminal).width).toBeGreaterThan(original[0].width);
    expect(rectangle(files).width).toBeLessThan(original[1].width);
    expectSeparated([terminal, files]);
    await user.keyboard('{Escape}');

    const divider = screen.getByRole('separator', { name: 'Main tile split' });
    await user.click(divider);
    await user.keyboard('{ArrowLeft}');
    expect(divider).toHaveAttribute('aria-valuenow', '60');
    await user.keyboard('{Home}{ArrowLeft}');
    expect(divider).toHaveAttribute('aria-valuenow', '30');
    await user.keyboard('{End}{ArrowRight}');
    expect(divider).toHaveAttribute('aria-valuenow', '70');
    expectSeparated([terminal, files]);

    await user.click(screen.getByRole('button', { name: 'Workspace 2' }));
    await user.click(screen.getByRole('button', { name: 'Tiling layout' }));
    expect(screen.getByRole('slider', { name: 'Main tile width' })).toHaveValue('50');
    fireEvent.change(screen.getByRole('slider', { name: 'Main tile width' }), { target: { value: '40' } });
    await user.keyboard('{Escape}');
    await user.click(screen.getByRole('button', { name: 'Workspace 1' }));
    await user.click(screen.getByRole('button', { name: 'Tiling layout' }));
    expect(screen.getByRole('slider', { name: 'Main tile width' })).toHaveValue('70');
    await user.click(screen.getByRole('button', { name: 'Reset split' }));
    expect(screen.getByRole('slider', { name: 'Main tile width' })).toHaveValue('50');
    expect([terminal, files].map(rectangle)).toEqual(original);
  });

  it('stacks narrow-screen tiles and recomputes nonoverlapping geometry after resizing', async () => {
    vi.stubGlobal('innerWidth', 390);
    vi.stubGlobal('innerHeight', 700);
    const user = userEvent.setup();
    const { terminal } = await startDesktop(user);
    const files = await openFiles(user);
    const { notes } = await openNotes(user);
    const windows = [terminal, files, notes];
    expectSeparated(windows);
    const narrow = windows.map(rectangle);
    expect(new Set(narrow.map(rect => rect.left)).size).toBe(1);
    expect(new Set(narrow.map(rect => rect.width)).size).toBe(1);
    expect(narrow[1].top).toBeGreaterThan(narrow[0].top + narrow[0].height);
    expect(narrow[2].top).toBeGreaterThan(narrow[1].top + narrow[1].height);

    vi.stubGlobal('innerWidth', 1440);
    vi.stubGlobal('innerHeight', 900);
    fireEvent(window, new Event('resize'));
    expectSeparated(windows);
    expect(rectangle(terminal).width).toBeGreaterThan(narrow[0].width);
    expect(rectangle(files).left).toBeGreaterThan(rectangle(terminal).left);
    expect(windows.every(win => rectangle(win).top + rectangle(win).height <= innerHeight)).toBe(true);
  });
});
