import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fireEvent, render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import Desktop from '../components/Desktop';
import { STORAGE_KEY } from '../lib/desktop';
import { DEFAULT_PREFERENCES } from '../lib/types';

beforeEach(() => localStorage.clear());
afterEach(() => vi.useRealTimers());

describe('native welcome and shell', () => {
  it('applies a welcome wallpaper and its colors, then restores the selection on a fresh visit', async () => {
    const user = userEvent.setup();
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ ...DEFAULT_PREFERENCES, clock24: false }));
    const firstVisit = render(<Desktop />);
    const welcome = screen.getByRole('region', { name: 'Welcome to NerdOS window' });
    expect(within(welcome).getByRole('button', { name: 'Use wallpaper Moonlit peaks' })).toHaveAttribute('aria-pressed', 'true');

    await user.click(within(welcome).getByRole('button', { name: 'Use wallpaper Aurora' }));

    expect(within(welcome).getByRole('button', { name: 'Use wallpaper Aurora' })).toHaveAttribute('aria-pressed', 'true');
    expect(within(welcome).getByRole('button', { name: 'Use wallpaper Moonlit peaks' })).toHaveAttribute('aria-pressed', 'false');
    expect(firstVisit.container.querySelector('.desktop-wallpaper')).toHaveClass('wallpaper-aurora');
    expect(screen.getByRole('main').style.getPropertyValue('--accent')).toBe('#a6c7a0');
    expect(JSON.parse(localStorage.getItem(STORAGE_KEY)!)).toEqual({
      ...DEFAULT_PREFERENCES, clock24: false, wallpaper: 'aurora', accent: '#a6c7a0',
    });

    firstVisit.unmount();
    const secondVisit = render(<Desktop />);
    const restoredWelcome = screen.getByRole('region', { name: 'Welcome to NerdOS window' });
    expect(within(restoredWelcome).getByRole('button', { name: 'Use wallpaper Aurora' })).toHaveAttribute('aria-pressed', 'true');
    expect(within(restoredWelcome).getByRole('button', { name: 'Use wallpaper Moonlit peaks' })).toHaveAttribute('aria-pressed', 'false');
    expect(secondVisit.container.querySelector('.desktop-wallpaper')).toHaveClass('wallpaper-aurora');
    expect(screen.getByRole('main').style.getPropertyValue('--accent')).toBe('#a6c7a0');
  });

  it('finishes welcome and opens the launcher from the empty desktop prompt', async () => {
    const user = userEvent.setup();
    render(<Desktop />);
    await user.click(screen.getByRole('button', { name: 'Get started' }));

    expect(screen.queryByRole('region', { name: 'Welcome to NerdOS window' })).not.toBeInTheDocument();
    const prompt = screen.getByRole('button', { name: /^Open an app/ });
    expect(prompt).toBeVisible();
    await user.click(prompt);
    const launcher = screen.getByRole('dialog', { name: 'App launcher' });
    expect(within(launcher).getByRole('textbox', { name: 'Search applications' })).toHaveFocus();
  });

  it('opens the matching drawer section from the bar and shares controls across tabs', async () => {
    const user = userEvent.setup();
    const { container } = render(<Desktop />);
    await user.click(screen.getByRole('button', { name: 'Open sound controls' }));
    expect(screen.getByRole('tab', { name: 'Sound' })).toHaveAttribute('aria-selected', 'true');
    fireEvent.change(within(screen.getByRole('tabpanel', { name: 'Sound' })).getByRole('slider', { name: 'Demo volume' }), { target: { value: '37' } });

    await user.click(screen.getByRole('button', { name: 'Open network controls' }));
    expect(screen.getByRole('tab', { name: 'Network' })).toHaveAttribute('aria-selected', 'true');
    const network = screen.getByRole('tabpanel', { name: 'Network' });
    await user.click(within(network).getByRole('button', { name: 'Wi-Fi' }));
    expect(within(network).getByRole('heading', { name: 'Wi-Fi is off' })).toBeVisible();

    await user.click(screen.getByRole('button', { name: 'Open power controls' }));
    expect(screen.getByRole('tab', { name: 'Power' })).toHaveAttribute('aria-selected', 'true');
    const power = screen.getByRole('tabpanel', { name: 'Power' });
    fireEvent.change(within(power).getByRole('slider', { name: 'Demo wallpaper brightness' }), { target: { value: '45' } });
    await user.click(within(power).getByRole('button', { name: 'Dark mode' }));
    expect(container.querySelector('.desktop-wallpaper')).toHaveStyle({ filter: 'brightness(0.45)' });
    expect(screen.getByRole('main')).toHaveClass('theme-light');

    await user.click(screen.getByRole('tab', { name: 'Overview' }));
    const overview = screen.getByRole('tabpanel', { name: 'Overview' });
    expect(within(overview).getByRole('slider', { name: 'Demo volume' })).toHaveValue('37');
    expect(within(overview).getByRole('slider', { name: 'Demo wallpaper brightness' })).toHaveValue('45');
    expect(within(overview).getByRole('button', { name: /^Wi-Fi/ })).toHaveAttribute('aria-pressed', 'false');
    expect(within(overview).getByRole('button', { name: /^Wi-Fi/ })).toHaveTextContent('Disconnected');
    expect(within(overview).getByRole('button', { name: /^Dark mode/ })).toHaveAttribute('aria-pressed', 'false');
    await user.click(within(overview).getByRole('button', { name: /^Wi-Fi/ }));

    await user.click(screen.getByRole('tab', { name: 'Network' }));
    expect(within(screen.getByRole('tabpanel', { name: 'Network' })).getByRole('button', { name: 'Wi-Fi' })).toHaveAttribute('aria-pressed', 'true');
    await user.click(screen.getByRole('button', { name: 'Close control panel' }));
    await user.click(screen.getByRole('button', { name: 'Open sound controls' }));
    expect(within(screen.getByRole('tabpanel', { name: 'Sound' })).getByRole('slider', { name: 'Demo volume' })).toHaveValue('37');
  });

  it('moves drawer selection and keyboard focus with ArrowRight, End, and Home', async () => {
    const user = userEvent.setup();
    render(<Desktop />);
    await user.click(screen.getByRole('button', { name: 'Open control panel' }));
    const overview = screen.getByRole('tab', { name: 'Overview' });
    expect(overview).toHaveFocus();
    expect(overview).toHaveAttribute('tabindex', '0');

    await user.keyboard('{ArrowRight}');
    const sound = screen.getByRole('tab', { name: 'Sound' });
    expect(sound).toHaveFocus();
    expect(sound).toHaveAttribute('aria-selected', 'true');
    expect(sound).toHaveAttribute('tabindex', '0');
    expect(overview).toHaveAttribute('aria-selected', 'false');
    expect(overview).toHaveAttribute('tabindex', '-1');
    expect(screen.getByRole('tabpanel', { name: 'Sound' })).toBeVisible();

    await user.keyboard('{End}');
    const notifications = screen.getByRole('tab', { name: 'Notifications' });
    expect(notifications).toHaveFocus();
    expect(notifications).toHaveAttribute('aria-selected', 'true');
    expect(screen.getByRole('tabpanel', { name: 'Notifications' })).toBeVisible();

    await user.keyboard('{Home}');
    expect(overview).toHaveFocus();
    expect(overview).toHaveAttribute('aria-selected', 'true');
    expect(notifications).toHaveAttribute('aria-selected', 'false');
    expect(notifications).toHaveAttribute('tabindex', '-1');
    expect(screen.getByRole('tabpanel', { name: 'Overview' })).toBeVisible();
  });

  it('uses the saved 12-hour preference in both the menubar and the day sheet', async () => {
    vi.useFakeTimers({ toFake: ['Date'] });
    const afternoon = new Date(2026, 8, 30, 14, 32);
    vi.setSystemTime(afternoon);
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ ...DEFAULT_PREFERENCES, clock24: false }));
    const user = userEvent.setup();
    render(<Desktop />);
    const calendarButton = screen.getByRole('button', { name: 'Open calendar' });
    expect(calendarButton).toHaveTextContent(afternoon.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: true }));
    await user.click(calendarButton);

    const calendar = screen.getByRole('dialog', { name: 'Calendar' });
    const parts = new Intl.DateTimeFormat([], { hour: '2-digit', minute: '2-digit', hour12: true }).formatToParts(afternoon);
    const period = parts.find(part => part.type === 'dayPeriod')!.value;
    const hour = parts.find(part => part.type === 'hour')!.value;
    const clock = within(calendar).getByText(period).closest('time');
    expect(clock).toBeVisible();
    expect(clock).toHaveAttribute('datetime', afternoon.toISOString());
    expect(clock).toHaveTextContent(`${hour}:32`);
    expect(clock).not.toHaveTextContent('14:32');
  });

  it('keeps focus in the drawer after clearing the last notifications', async () => {
    const user = userEvent.setup();
    render(<Desktop />);
    await user.click(screen.getByRole('button', { name: 'Notifications' }));
    const notifications = screen.getByRole('tabpanel', { name: 'Notifications' });
    expect(within(notifications).getByText('Welcome to your NerdOS browser desktop.')).toBeVisible();
    await user.click(within(notifications).getByRole('button', { name: 'Clear all' }));

    expect(within(notifications).getByRole('heading', { name: 'All caught up.' })).toBeVisible();
    expect(within(notifications).queryByRole('button', { name: 'Clear all' })).not.toBeInTheDocument();
    expect(screen.getByRole('tab', { name: 'Notifications' })).toHaveFocus();
  });
});
