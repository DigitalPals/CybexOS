import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import Desktop from '../components/Desktop';
import { STORAGE_KEY } from '../lib/desktop';
import { DEFAULT_PREFERENCES } from '../lib/types';

beforeEach(() => localStorage.clear());
afterEach(() => vi.unstubAllGlobals());

async function openTerminal(user: ReturnType<typeof userEvent.setup>) {
  await user.click(screen.getByRole('button', { name: 'Open app launcher' }));
  await user.type(screen.getByRole('textbox', { name: 'Search applications' }), 'terminal{Enter}');
  return screen.getByRole('region', { name: 'Kitty window' });
}

async function openSettings(user: ReturnType<typeof userEvent.setup>) {
  await user.click(screen.getByRole('button', { name: 'Open app launcher' }));
  const launcher = screen.getByRole('dialog', { name: 'App launcher' });
  await user.type(within(launcher).getByRole('textbox', { name: 'Search applications' }), 'settings');
  await user.click(within(launcher).getByRole('button', { name: /Settings.*Make this desktop yours/ }));
  return screen.getByRole('region', { name: 'Settings window' });
}

describe('desktop applications and windows', () => {
  it('opens apps from launcher search and recovers from a search with no results', async () => {
    const user = userEvent.setup();
    render(<Desktop />);

    await user.click(screen.getByRole('button', { name: 'Open app launcher' }));
    const launcher = screen.getByRole('dialog', { name: 'App launcher' });
    const search = within(launcher).getByRole('textbox', { name: 'Search applications' });
    expect(search).toHaveFocus();
    await user.type(search, 'missing-app-xyz');
    expect(within(launcher).getByText(/No apps found/)).toBeVisible();
    await user.click(within(launcher).getByRole('button', { name: 'Show all applications' }));
    expect(search).toHaveValue('');
    await user.type(search, 'terminal{Enter}');

    expect(screen.queryByRole('dialog', { name: 'App launcher' })).not.toBeInTheDocument();
    expect(screen.getByRole('region', { name: 'Kitty window' })).toBeVisible();
    const settings = await openSettings(user);
    expect(within(settings).getByRole('heading', { name: 'Appearance' })).toBeVisible();
  });

  it('keeps an app and its unfinished input when switching or moving between workspaces', async () => {
    const user = userEvent.setup();
    render(<Desktop />);
    const terminal = await openTerminal(user);
    await user.type(within(terminal).getByRole('textbox', { name: 'Terminal command' }), 'echo keep this draft');

    await user.click(screen.getByRole('button', { name: 'Workspace 2' }));
    expect(screen.queryByRole('region', { name: 'Kitty window' })).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: /Open an app/ })).toBeVisible();
    await user.click(screen.getByRole('button', { name: 'Workspace 1' }));
    expect(screen.getByRole('textbox', { name: 'Terminal command' })).toHaveValue('echo keep this draft');

    await user.selectOptions(within(terminal).getByRole('combobox', { name: 'Move Kitty to workspace' }), '3');
    expect(screen.queryByRole('region', { name: 'Kitty window' })).not.toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: 'Workspace 3' }));
    expect(screen.getByRole('textbox', { name: 'Terminal command' })).toHaveValue('echo keep this draft');
    expect(screen.getByRole('button', { name: 'Workspace 3' })).toHaveAttribute('aria-current', 'page');
  });

  it('restores minimized apps from the footer, maximizes them, and closes them', async () => {
    const user = userEvent.setup();
    render(<Desktop />);
    const terminal = await openTerminal(user);
    await user.type(within(terminal).getByRole('textbox', { name: 'Terminal command' }), 'pwd');

    await user.click(within(terminal).getByRole('button', { name: 'Minimize Kitty' }));
    expect(screen.queryByRole('region', { name: 'Kitty window' })).not.toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: 'Restore Kitty' }));
    expect(screen.getByRole('textbox', { name: 'Terminal command' })).toHaveValue('pwd');
    await user.click(within(terminal).getByRole('button', { name: 'Maximize Kitty' }));
    expect(terminal).toHaveClass('maximized');
    await user.click(within(terminal).getByRole('button', { name: 'Restore Kitty' }));
    expect(terminal).not.toHaveClass('maximized');
    await user.click(within(terminal).getByRole('button', { name: 'Close Kitty' }));
    expect(screen.queryByRole('region', { name: 'Kitty window' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Focus Kitty' })).not.toBeInTheDocument();
  });

  it('reopening an existing app focuses its window without discarding its contents', async () => {
    const user = userEvent.setup();
    render(<Desktop />);
    const terminal = await openTerminal(user);
    await user.type(within(terminal).getByRole('textbox', { name: 'Terminal command' }), 'echo one window');
    await openSettings(user);
    await openTerminal(user);

    expect(screen.getAllByRole('region', { name: 'Kitty window' })).toHaveLength(1);
    expect(terminal).toHaveClass('active');
    expect(within(terminal).getByRole('textbox', { name: 'Terminal command' })).toHaveValue('echo one window');
  });

  it('supports desktop keyboard shortcuts and dismisses the launcher with Escape', async () => {
    const user = userEvent.setup();
    render(<Desktop />);
    await user.keyboard('{Alt>}[Space]{/Alt}');
    expect(screen.getByRole('dialog', { name: 'App launcher' })).toBeVisible();
    await user.keyboard('{Escape}');
    expect(screen.queryByRole('dialog', { name: 'App launcher' })).not.toBeInTheDocument();
    await user.keyboard('{Alt>}5{/Alt}');
    expect(screen.getByRole('button', { name: 'Workspace 5' })).toHaveAttribute('aria-current', 'page');
    await user.keyboard('{Alt>}{Enter}{/Alt}');
    expect(screen.getByRole('region', { name: 'Kitty window' })).toBeVisible();
  });

  it('moves typing focus from a note to the terminal opened by Alt+Enter', async () => {
    const user = userEvent.setup();
    render(<Desktop />);
    await user.click(screen.getByRole('button', { name: 'Open notes' }));
    const editor = screen.getByRole('textbox', { name: 'Note content' });
    await waitFor(() => expect(editor).not.toHaveAttribute('readonly'));
    await user.clear(editor);
    await user.type(editor, 'Leave this note unchanged.');
    expect(editor).toHaveFocus();

    await user.keyboard('{Alt>}{Enter}{/Alt}');
    const terminal = screen.getByRole('region', { name: 'Kitty window' });
    const command = within(terminal).getByRole('textbox', { name: 'Terminal command' });
    await waitFor(() => expect(command).toHaveFocus());
    await user.keyboard('echo terminal only');

    expect(command).toHaveValue('echo terminal only');
    expect(editor).toHaveValue('Leave this note unchanged.');
    expect(localStorage.getItem('cybexos-demo-notes-v1')).toBe('Leave this note unchanged.');
    expect(terminal).toHaveClass('active');
  });

  it('raises an inactive app when keyboard navigation moves focus into it', async () => {
    const user = userEvent.setup();
    render(<Desktop />);
    await user.click(screen.getByRole('button', { name: 'Open notes' }));
    const notes = screen.getByRole('region', { name: 'Omawrite window' });
    const editor = within(notes).getByRole('textbox', { name: 'Note content' });
    await waitFor(() => expect(editor).not.toHaveAttribute('readonly'));
    const terminal = await openTerminal(user);
    await waitFor(() => expect(within(terminal).getByRole('textbox', { name: 'Terminal command' })).toHaveFocus());
    expect(notes).not.toHaveClass('active');
    await user.click(within(terminal).getByRole('combobox', { name: 'Move Kitty to workspace' }));
    await user.tab({ shift: true });

    expect(editor).toHaveFocus();
    expect(notes).toHaveClass('active');
    expect(terminal).not.toHaveClass('active');
    await user.click(within(terminal).getByRole('textbox', { name: 'Terminal command' }));
    expect(terminal).toHaveClass('active');
    expect(notes).not.toHaveClass('active');
  });

  it('keeps a note after closing its window and after a fresh desktop visit', async () => {
    const user = userEvent.setup();
    const firstVisit = render(<Desktop />);
    await user.click(screen.getByRole('button', { name: 'Open notes' }));
    const notes = screen.getByRole('region', { name: 'Omawrite window' });
    const editor = within(notes).getByRole('textbox', { name: 'Note content' });
    const writing = '# Keep this thought.\n\nFresh ideas tomorrow.';
    await waitFor(() => expect(editor).not.toHaveAttribute('readonly'));
    await user.clear(editor);
    await user.type(editor, writing);
    expect(within(notes).getByText('Saved in this browser')).toBeVisible();
    await user.click(within(notes).getByRole('button', { name: 'Preview note' }));
    expect(within(notes).getByRole('heading', { name: 'Keep this thought.' })).toBeVisible();
    await user.click(within(notes).getByRole('button', { name: 'Close Omawrite' }));
    await user.click(screen.getByRole('button', { name: 'Open notes' }));
    await waitFor(() => expect(screen.getByRole('textbox', { name: 'Note content' })).toHaveValue(writing));

    firstVisit.unmount();
    render(<Desktop />);
    await user.click(screen.getByRole('button', { name: 'Open notes' }));
    await waitFor(() => expect(screen.getByRole('textbox', { name: 'Note content' })).toHaveValue(writing));
  });

  it('browses sample folders, searches and previews files, and opens notes from Files', async () => {
    const user = userEvent.setup();
    render(<Desktop />);
    await user.click(within(screen.getByRole('region', { name: 'Welcome to CybexOS window' })).getByRole('button', { name: 'Files' }));
    const files = screen.getByRole('region', { name: 'Files window' });
    expect(within(files).getByRole('button', { name: 'Parent folder' })).toBeDisabled();
    await user.click(within(files).getByRole('button', { name: 'Open Documents' }));
    expect(within(files).getByRole('heading', { name: 'Documents' })).toBeVisible();
    const breadcrumb = within(files).getByRole('navigation', { name: 'Folder path' });
    expect(within(breadcrumb).getByRole('button', { name: 'Documents' })).toBeVisible();
    await user.type(within(files).getByRole('textbox', { name: 'Search this folder' }), 'short');
    expect(within(files).queryByRole('button', { name: 'Open My notes.md' })).not.toBeInTheDocument();
    await user.click(within(files).getByRole('button', { name: 'Open Shortcuts.txt' }));
    expect(within(files).getByText(/CybexOS browser shortcuts/)).toBeVisible();
    await user.click(within(files).getByRole('button', { name: 'Close file preview' }));
    await user.click(within(files).getByRole('button', { name: 'Clear file search' }));
    await user.click(within(files).getByRole('button', { name: 'Open My notes.md' }));
    expect(screen.getByRole('region', { name: 'Omawrite window' })).toBeVisible();

    await user.click(screen.getByRole('button', { name: 'Focus Files' }));
    await user.click(within(files).getByRole('button', { name: 'Parent folder' }));
    expect(within(files).getByRole('heading', { name: 'Home' })).toBeVisible();
    await user.click(within(files).getByRole('button', { name: 'Go back' }));
    expect(within(files).getByRole('heading', { name: 'Documents' })).toBeVisible();
    const places = within(files).getByRole('complementary', { name: 'Places' });
    await user.click(within(places).getByRole('button', { name: 'Downloads' }));
    expect(within(files).getByText('This sample folder is empty.')).toBeVisible();
    await user.click(within(files).getByRole('button', { name: 'Go back' }));
    expect(within(files).getByRole('heading', { name: 'Documents' })).toBeVisible();
  });
});

describe('desktop preferences', () => {
  it('applies settings immediately and restores them on a subsequent visit', async () => {
    const user = userEvent.setup();
    const firstVisit = render(<Desktop />);
    const settings = await openSettings(user);
    await user.click(within(settings).getByRole('radio', { name: 'Light' }));
    await user.click(within(settings).getByRole('radio', { name: 'Sky' }));
    await user.selectOptions(within(settings).getByRole('combobox', { name: 'Interface font' }), 'sans');
    await user.click(within(settings).getByRole('switch', { name: 'Glass surfaces' }));
    await user.click(within(settings).getByRole('switch', { name: 'Reduce motion' }));
    await user.click(within(settings).getByRole('button', { name: 'Wallpaper' }));
    await user.click(within(settings).getByRole('radio', { name: 'Aurora' }));
    await user.click(within(settings).getByRole('button', { name: 'Bar & clock' }));
    await user.click(within(settings).getByRole('switch', { name: '24-hour clock' }));
    expect(within(settings).getByText('2:32 PM')).toBeVisible();

    const expected = { theme: 'light', accent: '#9bbce0', font: 'sans', glass: true, reducedMotion: true, wallpaper: 'aurora', clock24: false };
    expect(JSON.parse(localStorage.getItem(STORAGE_KEY)!)).toEqual(expected);
    expect(screen.getByRole('main')).toHaveClass('theme-light', 'font-sans', 'glass-enabled', 'reduced-motion');
    expect(screen.getByRole('main').style.getPropertyValue('--accent')).toBe('#9bbce0');
    expect(firstVisit.container.querySelector('.desktop-wallpaper')).toHaveClass('wallpaper-aurora');

    firstVisit.unmount();
    const secondVisit = render(<Desktop />);
    expect(screen.getByRole('main')).toHaveClass('theme-light', 'font-sans', 'glass-enabled', 'reduced-motion');
    expect(secondVisit.container.querySelector('.desktop-wallpaper')).toHaveClass('wallpaper-aurora');
    const restoredSettings = await openSettings(user);
    expect(within(restoredSettings).getByRole('radio', { name: 'Light' })).toBeChecked();
    expect(within(restoredSettings).getByRole('switch', { name: 'Glass surfaces' })).toBeChecked();
  });

  it('requires an explicit reset confirmation and leaves saved notes alone', async () => {
    const user = userEvent.setup();
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ ...DEFAULT_PREFERENCES, theme: 'light', wallpaper: 'dusk' }));
    localStorage.setItem('cybexos-demo-notes-v1', 'Keep my writing.');
    render(<Desktop />);
    const settings = await openSettings(user);
    const reset = within(settings).getByRole('button', { name: 'Reset preferences' });
    await user.click(reset);
    const confirmation = within(settings).getByRole('group', { name: 'Confirm preference reset' });
    expect(screen.getByRole('main')).toHaveClass('theme-light');
    await user.click(within(confirmation).getByRole('button', { name: 'Cancel' }));
    expect(screen.getByRole('main')).toHaveClass('theme-light');
    expect(reset).toHaveFocus();
    await user.click(reset);
    await user.click(within(within(settings).getByRole('group', { name: 'Confirm preference reset' })).getByRole('button', { name: 'Reset preferences' }));

    expect(screen.getByRole('main')).toHaveClass('theme-dark');
    expect(JSON.parse(localStorage.getItem(STORAGE_KEY)!)).toEqual(DEFAULT_PREFERENCES);
    expect(localStorage.getItem('cybexos-demo-notes-v1')).toBe('Keep my writing.');
    expect(screen.getByRole('status')).toHaveTextContent('Desktop preferences restored');
  });

  it('starts safely when the saved settings are corrupt', () => {
    localStorage.setItem(STORAGE_KEY, '{broken');
    render(<Desktop />);
    expect(screen.getByRole('region', { name: 'Welcome to CybexOS window' })).toBeVisible();
    expect(screen.getByRole('main')).toHaveClass('theme-dark', 'font-mono');
    expect(screen.getByRole('main').style.getPropertyValue('--accent')).toBe(DEFAULT_PREFERENCES.accent);
  });
});

describe('desktop panels', () => {
  it('navigates the calendar across months and returns to the current month', async () => {
    const user = userEvent.setup();
    const today = new Date();
    const month = (date: Date) => date.toLocaleDateString([], { month: 'long', year: 'numeric' });
    render(<Desktop />);
    await user.click(screen.getByRole('button', { name: 'Open calendar' }));
    const calendar = screen.getByRole('dialog', { name: 'Calendar' });
    expect(within(calendar).getByRole('heading', { name: month(today) })).toBeVisible();
    await user.click(within(calendar).getByRole('button', { name: 'Next month' }));
    expect(within(calendar).getByRole('heading', { name: month(new Date(today.getFullYear(), today.getMonth() + 1, 1)) })).toBeVisible();
    await user.click(within(calendar).getByRole('button', { name: 'Previous month' }));
    await user.click(within(calendar).getByRole('button', { name: 'Previous month' }));
    expect(within(calendar).getByRole('heading', { name: month(new Date(today.getFullYear(), today.getMonth() - 1, 1)) })).toBeVisible();
    await user.click(within(calendar).getByRole('button', { name: /Back to today/ }));
    expect(within(calendar).getByRole('heading', { name: month(today) })).toBeVisible();
  });

  it('keeps simulated hardware controls local and explains what they change', async () => {
    const request = vi.fn();
    vi.stubGlobal('fetch', request);
    const user = userEvent.setup();
    const { container } = render(<Desktop />);
    await user.click(screen.getByRole('button', { name: 'Open control panel' }));
    const controls = screen.getByRole('dialog', { name: 'Control panel' });
    const wifi = within(controls).getByRole('button', { name: /Wi-Fi/ });
    const bluetooth = within(controls).getByRole('button', { name: /Bluetooth/ });
    expect(wifi).toHaveAttribute('aria-pressed', 'true');
    await user.click(wifi);
    await user.click(bluetooth);
    expect(wifi).toHaveAttribute('aria-pressed', 'false');
    expect(wifi).toHaveTextContent('Disconnected');
    expect(bluetooth).toHaveAttribute('aria-pressed', 'true');
    fireEvent.change(within(controls).getByRole('slider', { name: 'Demo wallpaper brightness' }), { target: { value: '45' } });
    expect(container.querySelector('.desktop-wallpaper')).toHaveStyle({ filter: 'brightness(0.45)' });
    expect(within(controls).getByText(/Network, audio, and battery are simulated/)).toBeVisible();
    expect(request).not.toHaveBeenCalled();
  });
});
