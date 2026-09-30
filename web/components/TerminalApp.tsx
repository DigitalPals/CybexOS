'use client';

import { useEffect, useRef, useState } from 'react';
import type { KeyboardEvent } from 'react';
import type { AppProps } from '../lib/types';
import { displayPath, HOME_PATH, runCommand, SYSTEM_INFO } from '../lib/terminal';

type Entry = { id: number; command: string; cwd: string; output: string };

export function TerminalApp({ openApp }: AppProps) {
  const [cwd, setCwd] = useState(HOME_PATH);
  const [input, setInput] = useState('');
  const [entries, setEntries] = useState<Entry[]>([{ id: 0, command: 'fastfetch', cwd: HOME_PATH, output: SYSTEM_INFO }]);
  const [history, setHistory] = useState<string[]>([]);
  const [historyIndex, setHistoryIndex] = useState(-1);
  const draft = useRef('');
  const nextId = useRef(1);
  const inputRef = useRef<HTMLInputElement>(null);
  const scrollRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (scrollRef.current) scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
  }, [entries]);

  const submit = () => {
    const command = input.trim();
    const result = runCommand(command, cwd);
    if (result.clear) setEntries([]);
    else setEntries((previous) => [...previous.slice(-149), { id: nextId.current++, command, cwd, output: result.output }]);
    if (command) setHistory((previous) => [command, ...previous].slice(0, 100));
    setCwd(result.cwd);
    setInput('');
    setHistoryIndex(-1);
    draft.current = '';
    if (result.openApp) openApp(result.openApp);
  };

  const onKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    if (event.key === 'Enter' && !event.altKey && !event.ctrlKey && !event.metaKey) { event.preventDefault(); submit(); }
    if (event.ctrlKey && event.key.toLowerCase() === 'l') { event.preventDefault(); setEntries([]); }
    if (event.key === 'ArrowUp') {
      event.preventDefault();
      if (historyIndex === -1) draft.current = input;
      const next = Math.min(historyIndex + 1, history.length - 1);
      setHistoryIndex(next);
      if (next >= 0) setInput(history[next]);
    }
    if (event.key === 'ArrowDown') {
      event.preventDefault();
      const next = Math.max(historyIndex - 1, -1);
      setHistoryIndex(next);
      setInput(next === -1 ? draft.current : history[next]);
    }
  };

  return (
    <div className="terminal-app" onClick={() => { if (!window.getSelection()?.toString()) inputRef.current?.focus(); }}>
      <div className="terminal-scroll" ref={scrollRef}>
        <div className="terminal-intro">Welcome home. Type <button onClick={(event) => { event.stopPropagation(); setInput('help'); inputRef.current?.focus(); }}>help</button> to find your way around.</div>
        <div className="terminal-history" role="log" aria-label="Terminal output" aria-live="polite">
          {entries.map((entry) => <div className="terminal-entry" key={entry.id}>
            <div className="terminal-command"><span className="terminal-user">guest@cybexos</span> <span className="terminal-path">{displayPath(entry.cwd)}</span><span className="terminal-chevron">❯</span> <span>{entry.command}</span></div>
            {entry.output && <pre className={entry.command === 'fastfetch' || entry.command === 'neofetch' ? 'terminal-system' : ''}>{entry.output}</pre>}
          </div>)}
        </div>
        <div className="terminal-prompt">
          <span className="terminal-user">guest@cybexos</span>
          <span className="terminal-path">{displayPath(cwd)}</span>
          <span className="terminal-chevron">❯</span>
          <input ref={inputRef} aria-label="Terminal command" spellCheck={false} autoCapitalize="off" autoComplete="off" autoCorrect="off" value={input} onChange={(event) => { setInput(event.target.value); setHistoryIndex(-1); }} onKeyDown={onKeyDown} />
        </div>
      </div>
      <footer className="terminal-status"><span><i /> Simulated shell</span><span>↑ ↓ history <span className="terminal-status-divider">/</span> Ctrl L clear</span></footer>
    </div>
  );
}
