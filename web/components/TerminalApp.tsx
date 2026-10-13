'use client';

import { useEffect, useRef, useState } from 'react';
import type { KeyboardEvent } from 'react';
import type { AppProps } from '../lib/types';
import { completeInput, displayPath, HOME_PATH, runCommand, SYSTEM_INFO } from '../lib/terminal';
import { Fastfetch } from './Fastfetch';

type Entry = { id: number; command: string; cwd: string; output: string; fastfetch?: boolean; cancelled?: boolean };

function PromptContext({ cwd }: { cwd: string }) {
  return <div className="terminal-prompt-context"><span className="terminal-user">guest<span>@</span>cybexos</span><span className="terminal-path">{displayPath(cwd)}</span></div>;
}

export function TerminalApp({ openApp }: AppProps) {
  const [cwd, setCwd] = useState(HOME_PATH);
  const [input, setInput] = useState('');
  const [entries, setEntries] = useState<Entry[]>([{ id: 0, command: 'fastfetch', cwd: HOME_PATH, output: SYSTEM_INFO, fastfetch: true }]);
  const [history, setHistory] = useState<string[]>([]);
  const [historyIndex, setHistoryIndex] = useState(-1);
  const [completions, setCompletions] = useState<string[]>([]);
  const draft = useRef('');
  const nextId = useRef(1);
  const inputRef = useRef<HTMLInputElement>(null);
  const scrollRef = useRef<HTMLDivElement>(null);
  const pendingCursor = useRef<number | null>(null);

  useEffect(() => {
    if (scrollRef.current) scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
  }, [entries, completions]);

  useEffect(() => {
    if (pendingCursor.current !== null) {
      inputRef.current?.setSelectionRange(pendingCursor.current, pendingCursor.current);
      pendingCursor.current = null;
    }
  }, [input]);

  const resetInput = () => {
    setInput('');
    setHistoryIndex(-1);
    setCompletions([]);
    draft.current = '';
  };

  const submit = () => {
    const command = input.trim();
    const result = runCommand(command, cwd);
    const nextHistory = command ? [command, ...history].slice(0, 100) : history;
    const output = result.presentation === 'history'
      ? [...nextHistory].reverse().map((item, index) => `${String(index + 1).padStart(4)}  ${item}`).join('\n')
      : result.output;
    if (result.clear) setEntries([]);
    else setEntries((previous) => [...previous.slice(-149), { id: nextId.current++, command, cwd, output, fastfetch: result.presentation === 'fastfetch' }]);
    setHistory(nextHistory);
    setCwd(result.cwd);
    resetInput();
    if (result.openApp) openApp(result.openApp);
  };

  const onKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    // Desktop navigation must still work while the terminal input has focus.
    if (event.altKey || event.metaKey || event.nativeEvent.isComposing) return;
    if (event.ctrlKey) {
      if (event.shiftKey) return;
      const key = event.key.toLowerCase();
      if (key === 'l') { event.preventDefault(); setEntries([]); setCompletions([]); }
      if (key === 'u') { event.preventDefault(); resetInput(); }
      if (key === 'c' && !window.getSelection()?.toString() && inputRef.current?.selectionStart === inputRef.current?.selectionEnd) {
        event.preventDefault();
        setEntries((previous) => [...previous.slice(-149), { id: nextId.current++, command: input, cwd, output: '', cancelled: true }]);
        resetInput();
      }
      return;
    }
    if (event.key === 'Enter') { event.preventDefault(); submit(); return; }
    if (event.key === 'Tab' && !event.shiftKey) {
      event.preventDefault();
      const completion = completeInput(input, cwd, inputRef.current?.selectionStart ?? input.length);
      pendingCursor.current = completion.cursor;
      setInput(completion.input);
      setCompletions(completion.candidates);
      setHistoryIndex(-1);
      // React does not render an unchanged input; restore the caret directly too.
      if (completion.input === input) {
        inputRef.current?.setSelectionRange(completion.cursor, completion.cursor);
        pendingCursor.current = null;
      }
      return;
    }
    if (event.key === 'ArrowUp' && !event.shiftKey) {
      event.preventDefault();
      if (!history.length) return;
      if (historyIndex === -1) draft.current = input;
      const next = Math.min(historyIndex + 1, history.length - 1);
      setHistoryIndex(next);
      setInput(history[next]);
      setCompletions([]);
    }
    if (event.key === 'ArrowDown' && !event.shiftKey) {
      event.preventDefault();
      if (historyIndex === -1) return;
      const next = Math.max(historyIndex - 1, -1);
      setHistoryIndex(next);
      setInput(next === -1 ? draft.current : history[next]);
      setCompletions([]);
    }
  };

  return (
    <div className="terminal-app" onClick={() => { if (!window.getSelection()?.toString()) inputRef.current?.focus(); }}>
      <div className="terminal-scroll" ref={scrollRef}>
        <div className="terminal-intro"><span>fish <span className="terminal-intro-version">4.3</span> <span className="terminal-intro-divider">/</span> Welcome to CybexOS</span><button onClick={(event) => { event.stopPropagation(); setInput('help'); setHistoryIndex(-1); setCompletions([]); inputRef.current?.focus(); }}>help ↵</button></div>
        <div className="terminal-history" role="log" aria-label="Terminal output" aria-live="polite">
          {entries.map((entry) => <div className="terminal-entry" key={entry.id}>
            <div className="terminal-command">
              <PromptContext cwd={entry.cwd} />
              <div className="terminal-command-line"><span className="terminal-chevron" aria-hidden="true">❯</span><span>{entry.command}{entry.cancelled && <span className="terminal-interrupt">^C</span>}</span></div>
            </div>
            {entry.fastfetch ? <Fastfetch /> : entry.output && <pre>{entry.output}</pre>}
          </div>)}
        </div>
        <div className="terminal-active-prompt">
          <PromptContext cwd={cwd} />
          <div className="terminal-prompt">
            <span className="terminal-chevron" aria-hidden="true">❯</span>
            <input ref={inputRef} aria-label="Terminal command" spellCheck={false} autoCapitalize="off" autoComplete="off" autoCorrect="off" value={input} onChange={(event) => { setInput(event.target.value); draft.current = event.target.value; setHistoryIndex(-1); setCompletions([]); }} onKeyDown={onKeyDown} />
          </div>
          {!!completions.length && <div className="terminal-completions" role="status" aria-label="Completion suggestions">{completions.map((completion) => <span key={completion}>{completion}</span>)}</div>}
        </div>
      </div>
      <footer className="terminal-status"><span><i /> fish · simulated</span><span className="terminal-status-hints">Tab complete <span className="terminal-status-divider">/</span> ↑ ↓ history <span className="terminal-status-divider">/</span> Ctrl L clear</span></footer>
    </div>
  );
}
