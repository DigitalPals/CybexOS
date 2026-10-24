'use client';

import { useRef, useState, type CSSProperties, type ReactNode } from 'react';
import {
  Accessibility, ArrowUpRight, Check, Clock3, Info, Layers3, Moon,
  Palette, PanelTop, RotateCcw, Settings2, ShieldCheck, Sun, Type, Wallpaper,
} from 'lucide-react';
import { DEFAULT_PREFERENCES, REPOSITORY_URL, type Preferences, type SettingsPage } from '../lib/types';
import './settings.css';

interface SettingsAppProps {
  preferences: Preferences;
  updatePreferences: (patch: Partial<Preferences>) => void;
  notify: (message: string) => void;
}

const pages = [
  { id: 'appearance', label: 'Appearance', icon: Palette },
  { id: 'wallpaper', label: 'Wallpaper', icon: Wallpaper },
  { id: 'bar', label: 'Bar & clock', icon: PanelTop },
  { id: 'about', label: 'About', icon: Info },
] as const;

const accents = [
  { label: 'Cybex blue', color: '#60a5fa' },
  { label: 'Moonstone', color: '#d3d283' },
  { label: 'Sage', color: '#a6c7a0' },
  { label: 'Sky', color: '#9bbce0' },
  { label: 'Lavender', color: '#c2a8e0' },
  { label: 'Rose', color: '#e4aaa1' },
];

const wallpapers = [
  { id: 'mountains', name: 'Moonlit peaks', detail: 'The Cybex OS original' },
  { id: 'aurora', name: 'Aurora', detail: 'A quieter kind of green' },
  { id: 'dusk', name: 'After hours', detail: 'The last light of the day' },
] as const;

function Toggle({ checked, onChange, label }: {
  checked: boolean; onChange: () => void; label: string;
}) {
  return (
    <button type="button" className="settings-toggle" role="switch"
      aria-checked={checked} aria-label={label} onClick={onChange}>
      <span />
    </button>
  );
}

function SettingRow({ icon, title, description, children }: {
  icon: ReactNode; title: string; description: string; children: ReactNode;
}) {
  return (
    <div className="settings-row">
      <span className="settings-row-icon" aria-hidden="true">{icon}</span>
      <div className="settings-row-copy">
        <div className="settings-row-title">{title}</div>
        <p>{description}</p>
      </div>
      <div className="settings-row-control">{children}</div>
    </div>
  );
}

export function SettingsApp({ preferences, updatePreferences, notify }: SettingsAppProps) {
  const [page, setPage] = useState<SettingsPage>('appearance');
  const [confirmReset, setConfirmReset] = useState(false);
  const resetButton = useRef<HTMLButtonElement>(null);

  function resetPreferences() {
    updatePreferences({ ...DEFAULT_PREFERENCES });
    setConfirmReset(false);
    notify('Desktop preferences restored to Cybex OS defaults.');
    resetButton.current?.focus();
  }

  return (
    <div className="settings-app">
      <nav className="settings-sidebar" aria-label="Settings pages">
        <div className="settings-sidebar-heading"><Settings2 size={16} /><span>Your desktop</span></div>
        <div className="settings-navigation">
          {pages.map(({ id, label, icon: Icon }) => (
            <button key={id} type="button" className={page === id ? 'is-current' : ''}
              aria-current={page === id ? 'page' : undefined}
              onClick={() => { setPage(id); setConfirmReset(false); }}>
              <Icon size={17} aria-hidden="true" /><span>{label}</span>
            </button>
          ))}
        </div>
        <div className="settings-sidebar-footer"><span className="settings-local-dot" />Saved in this browser</div>
      </nav>

      <div className="settings-main">
        {page === 'appearance' && (
          <section aria-labelledby="settings-appearance-heading">
            <header className="settings-page-heading">
              <span className="settings-eyebrow">MAKE YOURSELF AT HOME</span>
              <h2 id="settings-appearance-heading">Appearance</h2>
              <p>A little more you. Changes apply as you go.</p>
            </header>

            <fieldset className="settings-fieldset">
              <legend>Color mode</legend>
              <div className="settings-theme-options">
                {(['dark', 'light'] as const).map(theme => (
                  <label key={theme} className={`settings-theme-option settings-theme-${theme}`}>
                    <input type="radio" name="settings-theme" value={theme}
                      checked={preferences.theme === theme}
                      onChange={() => updatePreferences({ theme })} />
                    <span className="settings-theme-preview" aria-hidden="true">
                      <span className="settings-mini-bar"><i /><i /><i /></span>
                      <span className="settings-mini-window"><i /><i /><i /></span>
                      <span className="settings-theme-check"><Check size={13} /></span>
                    </span>
                    <span className="settings-theme-label">
                      {theme === 'dark' ? <Moon size={14} /> : <Sun size={14} />}
                      {theme === 'dark' ? 'Dark' : 'Light'}
                    </span>
                  </label>
                ))}
              </div>
            </fieldset>

            <fieldset className="settings-fieldset settings-accent-fieldset">
              <legend>Accent color</legend>
              <div className="settings-accent-colors">
                {accents.map(({ label, color }) => (
                  <label key={color} className="settings-accent-option"
                    style={{ '--picker-accent': color } as CSSProperties} title={label}>
                    <input type="radio" name="settings-accent" aria-label={label}
                      checked={preferences.accent === color}
                      onChange={() => updatePreferences({ accent: color })} />
                    <span>{preferences.accent === color && <Check size={17} aria-hidden="true" />}</span>
                  </label>
                ))}
                <span className="settings-accent-name">
                  {accents.find(accent => accent.color === preferences.accent)?.label ?? 'Custom'}
                </span>
              </div>
            </fieldset>

            <div className="settings-group">
              <SettingRow icon={<Type size={18} />} title="Interface font" description="The voice of your desktop.">
                <select aria-label="Interface font" value={preferences.font}
                  onChange={event => updatePreferences({ font: event.target.value as Preferences['font'] })}>
                  <option value="mono">JetBrains Mono</option>
                  <option value="sans">Figtree</option>
                </select>
              </SettingRow>
              <SettingRow icon={<Layers3 size={18} />} title="Glass surfaces" description="Let a little of your wallpaper through.">
                <Toggle label="Glass surfaces" checked={preferences.glass}
                  onChange={() => updatePreferences({ glass: !preferences.glass })} />
              </SettingRow>
              <SettingRow icon={<Accessibility size={18} />} title="Reduce motion" description="Keep transitions calm and instant.">
                <Toggle label="Reduce motion" checked={preferences.reducedMotion}
                  onChange={() => updatePreferences({ reducedMotion: !preferences.reducedMotion })} />
              </SettingRow>
            </div>
          </section>
        )}

        {page === 'wallpaper' && (
          <section aria-labelledby="settings-wallpaper-heading">
            <header className="settings-page-heading">
              <span className="settings-eyebrow">A DIFFERENT PERSPECTIVE</span>
              <h2 id="settings-wallpaper-heading">Wallpaper</h2>
              <p>Set the scene for your next idea.</p>
            </header>
            <fieldset className="settings-fieldset settings-wallpaper-fieldset">
              <legend className="settings-sr-only">Desktop wallpaper</legend>
              <div className="settings-wallpapers">
                {wallpapers.map(({ id, name, detail }) => (
                  <label className="settings-wallpaper-option" key={id}>
                    <input type="radio" name="settings-wallpaper" aria-label={name}
                      checked={preferences.wallpaper === id}
                      onChange={() => updatePreferences({ wallpaper: id })} />
                    <span className={`settings-wallpaper-image wallpaper-${id}`}>
                      <span className="settings-wallpaper-check"><Check size={15} /></span>
                    </span>
                    <span className="settings-wallpaper-name">{name}</span>
                    <span className="settings-wallpaper-description">{detail}</span>
                  </label>
                ))}
              </div>
            </fieldset>
            <div className="settings-help-note"><Info size={16} /><p>Your wallpaper choice stays in this browser, ready for your next visit.</p></div>
          </section>
        )}

        {page === 'bar' && (
          <section aria-labelledby="settings-bar-heading">
            <header className="settings-page-heading">
              <span className="settings-eyebrow">EVERYTHING AT A GLANCE</span>
              <h2 id="settings-bar-heading">Bar & clock</h2>
              <p>A small bar. A clear view of your day.</p>
            </header>
            <div className="settings-clock-preview">
              <Clock3 size={22} />
              <span>{preferences.clock24 ? '14:32' : '2:32 PM'}</span>
              <small>Clock format preview</small>
            </div>
            <div className="settings-group">
              <SettingRow icon={<Clock3 size={18} />} title="24-hour clock" description="Use 14:32 instead of 2:32 PM.">
                <Toggle label="24-hour clock" checked={preferences.clock24}
                  onChange={() => updatePreferences({ clock24: !preferences.clock24 })} />
              </SettingRow>
            </div>
            <div className="settings-help-note"><PanelTop size={16} /><p>The bar gives you five workspaces, your open apps, a calendar, and quick settings. Click a workspace number to find a little more room.</p></div>
          </section>
        )}

        {page === 'about' && (
          <section aria-labelledby="settings-about-heading">
            <header className="settings-page-heading">
              <span className="settings-eyebrow">A DESKTOP THAT FEELS LIKE YOURS</span>
              <h2 id="settings-about-heading">Cybex OS</h2>
              <p>Thoughtfully simple. Unmistakably personal.</p>
            </header>
            <div className="settings-about-brand"><img src="/cybexos-logo.svg" alt="Cybex OS" width="240" height="57" /><small>THE CYBEX OS BROWSER EXPERIENCE</small></div>
            <div className="settings-group settings-about-facts">
              <div><span>Native foundation</span><strong>NixOS 26.05</strong></div>
              <div><span>Window compositor</span><strong>Hyprland</strong></div>
              <div><span>Desktop shell</span><strong>Quickshell</strong></div>
              <div><span>This experience</span><strong>Interactive web demo</strong></div>
            </div>
            <div className="settings-help-note settings-about-note"><ShieldCheck size={18} /><p>This is an interactive simulation of Cybex OS. It does not install Linux or control your computer. Notes and preferences are stored locally in this browser.</p></div>
            <a className="settings-repository-link" href={REPOSITORY_URL} target="_blank" rel="noreferrer">
              Explore Cybex OS on GitHub <ArrowUpRight size={16} />
            </a>
          </section>
        )}

        <footer className="settings-footer">
          <button type="button" className="settings-reset" ref={resetButton}
            aria-expanded={confirmReset} aria-controls="settings-reset-confirmation"
            onClick={() => setConfirmReset(value => !value)}>
            <RotateCcw size={13} />Reset preferences
          </button>
          {confirmReset && (
            <div className="settings-reset-confirmation" id="settings-reset-confirmation"
              role="group" aria-label="Confirm preference reset">
              <p>Restore the default theme, wallpaper, and desktop settings? Your notes will stay.</p>
              <div>
                <button type="button" onClick={() => { setConfirmReset(false); resetButton.current?.focus(); }}>Cancel</button>
                <button type="button" className="settings-confirm-button" onClick={resetPreferences}>Reset preferences</button>
              </div>
            </div>
          )}
        </footer>
      </div>
    </div>
  );
}
