'use client';

import { useEffect, useId, useRef, type CSSProperties, type Dispatch, type SetStateAction } from 'react';
import { BatteryFull, Bell, BellOff, Bluetooth, Check, ChevronRight, Command, Grid2X2, Headphones, Keyboard, LockKeyhole, Moon, Settings2, Sun, Volume2, VolumeX, Wifi, WifiOff, X, type LucideIcon } from 'lucide-react';
import type { AppId, Preferences } from '../lib/types';
import { Overlay } from './Overlay';

export type DrawerTab = 'overview' | 'sound' | 'network' | 'bluetooth' | 'power' | 'notifications';

interface ControlDrawerProps {
  tab: DrawerTab;
  setTab: (tab: DrawerTab) => void;
  close: () => void;
  volume: number;
  setVolume: (value: number) => void;
  brightness: number;
  setBrightness: (value: number) => void;
  wifi: boolean;
  setWifi: (value: boolean) => void;
  bluetooth: boolean;
  setBluetooth: (value: boolean) => void;
  dnd: boolean;
  setDnd: (value: boolean) => void;
  preferences: Preferences;
  updatePreferences: (patch: Partial<Preferences>) => void;
  notices: string[];
  setNotices: Dispatch<SetStateAction<string[]>>;
  openApp: (app: AppId) => void;
  lock: () => void;
}

const TABS: { id: DrawerTab; label: string; icon: LucideIcon }[] = [
  { id: 'overview', label: 'Overview', icon: Grid2X2 },
  { id: 'sound', label: 'Sound', icon: Volume2 },
  { id: 'network', label: 'Network', icon: Wifi },
  { id: 'bluetooth', label: 'Bluetooth', icon: Bluetooth },
  { id: 'power', label: 'Power', icon: BatteryFull },
  { id: 'notifications', label: 'Notifications', icon: Bell },
];

function Slider({ icon: Icon, label, value, min = 0, onChange }: { icon: LucideIcon; label: string; value: number; min?: number; onChange: (value: number) => void }) {
  return <label className="drawer-slider">
    <Icon size={19} aria-hidden="true" />
    <input aria-label={label} type="range" min={min} max={100} value={value} onChange={event => onChange(Number(event.target.value))} style={{ '--slider-fill': `${(value - min) / (100 - min) * 100}%` } as CSSProperties} />
    <output>{value}%</output>
  </label>;
}

function Toggle({ icon: Icon, label, detail, on, toggle }: { icon: LucideIcon; label: string; detail: string; on: boolean; toggle: () => void }) {
  return <button className={`drawer-toggle ${on ? 'on' : ''}`} aria-pressed={on} onClick={toggle}>
    <Icon size={20} aria-hidden="true" /><strong>{label}</strong><small>{detail}</small>
  </button>;
}

function SwitchRow({ icon: Icon, label, on, toggle }: { icon: LucideIcon; label: string; on: boolean; toggle: () => void }) {
  return <button className="drawer-switch-row" aria-pressed={on} onClick={toggle}>
    <Icon size={19} aria-hidden="true" /><span>{label}</span><span className={`drawer-switch ${on ? 'on' : ''}`} aria-hidden="true"><span /></span>
  </button>;
}

export function ControlDrawer({ tab, setTab, close, volume, setVolume, brightness, setBrightness, wifi, setWifi, bluetooth, setBluetooth, dnd, setDnd, preferences, updatePreferences, notices, setNotices, openApp, lock }: ControlDrawerProps) {
  const id = useId();
  const tabs = useRef<Partial<Record<DrawerTab, HTMLButtonElement | null>>>({});
  const body = useRef<HTMLDivElement>(null);

  useEffect(() => {
    tabs.current[tab]?.focus();
    if (body.current) body.current.scrollTop = 0;
  }, [tab]);

  const volumeSlider = <Slider icon={volume ? Volume2 : VolumeX} label="Demo volume" value={volume} onChange={setVolume} />;
  const brightnessSlider = <Slider icon={Sun} label="Demo wallpaper brightness" min={30} value={brightness} onChange={setBrightness} />;

  return <Overlay label={tab === 'notifications' ? 'Notifications' : 'Control panel'} className="control-drawer" close={close}>
    <div className="drawer-tabs" role="tablist" aria-label="Control panel sections">
      {TABS.map(({ id: key, label, icon: Icon }, index) => <button
        key={key}
        ref={element => { tabs.current[key] = element; }}
        id={`${id}-tab-${key}`}
        role="tab"
        aria-selected={tab === key}
        aria-controls={`${id}-panel`}
        aria-label={label}
        title={label}
        tabIndex={tab === key ? 0 : -1}
        onClick={() => setTab(key)}
        onKeyDown={event => {
          let next = index;
          if (event.key === 'ArrowLeft') next = Math.max(0, index - 1);
          else if (event.key === 'ArrowRight') next = Math.min(TABS.length - 1, index + 1);
          else if (event.key === 'Home') next = 0;
          else if (event.key === 'End') next = TABS.length - 1;
          else return;
          event.preventDefault();
          setTab(TABS[next].id);
          tabs.current[TABS[next].id]?.focus();
        }}
      ><Icon size={16} aria-hidden="true" />{tab === key && <span>{label}</span>}{key === 'notifications' && notices.length > 0 && tab !== key && <i className="drawer-unread" />}</button>)}
    </div>

    <div className="drawer-body" ref={body} role="tabpanel" id={`${id}-panel`} aria-labelledby={`${id}-tab-${tab}`}>
      {tab === 'overview' && <>
        <div className="drawer-system">
          <div className="drawer-system-identity"><img src="/fedora.svg" width="48" height="48" alt="" /><div><h2>Fedora Linux</h2><p>Version 44 · CybexOS</p><span>Hyprland desktop</span></div><span className="drawer-demo-tag">DEMO</span></div>
          <div className="drawer-system-session"><span><span className="drawer-status-dot" />visitor@cybexos</span><span>Browser session</span></div>
        </div>
        <div className="drawer-sliders">{brightnessSlider}{volumeSlider}</div>
        <div className="drawer-toggles">
          <Toggle icon={wifi ? Wifi : WifiOff} label="Wi-Fi" detail={wifi ? 'Connected' : 'Disconnected'} on={wifi} toggle={() => setWifi(!wifi)} />
          <Toggle icon={Bluetooth} label="Bluetooth" detail={bluetooth ? 'On' : 'Off'} on={bluetooth} toggle={() => setBluetooth(!bluetooth)} />
          <Toggle icon={Moon} label="Dark mode" detail={preferences.theme === 'dark' ? 'On' : 'Off'} on={preferences.theme === 'dark'} toggle={() => updatePreferences({ theme: preferences.theme === 'dark' ? 'light' : 'dark' })} />
          <Toggle icon={BellOff} label="Focus" detail={dnd ? 'On' : 'Off'} on={dnd} toggle={() => setDnd(!dnd)} />
        </div>
        <div className="drawer-links">
          <button onClick={() => openApp('settings')}><Settings2 size={17} /><span>Settings</span><ChevronRight size={15} /></button>
          <button onClick={() => openApp('shortcuts')}><Keyboard size={17} /><span>Keyboard shortcuts</span><ChevronRight size={15} /></button>
        </div>
        <p className="drawer-note">Network, audio, and battery are simulated. Brightness changes the demo wallpaper.</p>
      </>}

      {tab === 'sound' && <>
        <div className="drawer-section-heading"><h2>Sound</h2><span>Demo audio</span></div>
        <div className="drawer-device"><Headphones size={23} /><div><strong>Built-in audio</strong><span>Default output · simulated</span></div><Check size={16} /></div>
        <div className="drawer-section-label">OUTPUT VOLUME</div>
        {volumeSlider}
        <SwitchRow icon={VolumeX} label="Mute output" on={volume === 0} toggle={() => setVolume(volume === 0 ? 68 : 0)} />
        <p className="drawer-note">Explore the audio controls here. Your device’s volume stays unchanged.</p>
      </>}

      {tab === 'network' && <>
        <div className="drawer-section-heading"><h2>Network</h2><span>{wifi ? 'Connected' : 'Disconnected'}</span></div>
        <SwitchRow icon={wifi ? Wifi : WifiOff} label="Wi-Fi" on={wifi} toggle={() => setWifi(!wifi)} />
        {wifi ? <><div className="drawer-section-label">CURRENT CONNECTION</div><div className="drawer-device"><Wifi size={23} /><div><strong>Cybex network</strong><span>Demo wireless connection</span></div><Check size={16} /></div><dl className="drawer-details"><div><dt>Signal</dt><dd>Excellent</dd></div><div><dt>Security</dt><dd>WPA3</dd></div></dl></> : <div className="drawer-empty"><WifiOff size={29} /><h3>Wi-Fi is off</h3><p>Turn it on to restore the demo connection.</p></div>}
        <p className="drawer-note">This sample connection demonstrates the installed desktop. Your network settings stay unchanged.</p>
      </>}

      {tab === 'bluetooth' && <>
        <div className="drawer-section-heading"><h2>Bluetooth</h2><span>{bluetooth ? 'On' : 'Off'}</span></div>
        <SwitchRow icon={Bluetooth} label="Bluetooth" on={bluetooth} toggle={() => setBluetooth(!bluetooth)} />
        <div className="drawer-empty"><Bluetooth size={29} /><h3>{bluetooth ? 'Ready to connect' : 'Bluetooth is off'}</h3><p>{bluetooth ? 'On Fedora, your nearby devices appear here.' : 'Turn it on to explore the Bluetooth panel.'}</p></div>
        <p className="drawer-note">Bluetooth is simulated in this browser session. No nearby devices are scanned.</p>
      </>}

      {tab === 'power' && <>
        <div className="drawer-section-heading"><h2>Power</h2><span>Demo battery</span></div>
        <div className="drawer-battery"><BatteryFull size={39} /><div><strong>100<span>%</span></strong><p>Fully charged</p></div><span>Plugged in</span></div>
        <div className="drawer-section-label">DISPLAY BRIGHTNESS</div>
        {brightnessSlider}
        <SwitchRow icon={Moon} label="Dark mode" on={preferences.theme === 'dark'} toggle={() => updatePreferences({ theme: preferences.theme === 'dark' ? 'light' : 'dark' })} />
        <p className="drawer-note">Brightness changes the wallpaper in this demo. Battery information is simulated.</p>
      </>}

      {tab === 'notifications' && <>
        <SwitchRow icon={BellOff} label="Do not disturb" on={dnd} toggle={() => setDnd(!dnd)} />
        <div className="drawer-notification-heading"><h2>Notifications <span>{notices.length}</span></h2>{notices.length > 0 && <button onClick={() => { tabs.current.notifications?.focus(); setNotices([]); }}>Clear all</button>}</div>
        {notices.length ? <div className="drawer-notices">{notices.map((notice, index) => <article className="drawer-notice" key={`${notice}-${index}`}><div><Command size={14} /><strong>CybexOS</strong><span>This session</span><button className="drawer-icon-button" aria-label={`Dismiss notification ${index + 1}`} onClick={() => { tabs.current.notifications?.focus(); setNotices(items => items.filter((_, itemIndex) => itemIndex !== index)); }}><X size={13} /></button></div><p>{notice}</p></article>)}</div> : <div className="drawer-empty"><Check size={30} /><h3>All caught up.</h3><p>New notifications will appear here.</p></div>}
        {dnd && <p className="drawer-note">Do not disturb is on. New notifications arrive quietly.</p>}
      </>}
    </div>

    <footer className="drawer-footer"><span>Browser session</span><button className="drawer-lock" aria-label="Lock demo" onClick={lock}><LockKeyhole size={14} />Lock</button><button className="drawer-icon-button" aria-label={tab === 'notifications' ? 'Close notifications' : 'Close control panel'} onClick={close}><X size={16} /></button></footer>
  </Overlay>;
}
