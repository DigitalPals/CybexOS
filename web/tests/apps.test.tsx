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
