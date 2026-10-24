'use client';

import { useEffect, useRef, useState } from 'react';
import { AlertCircle, Check, Download, Eye, FileText, Pencil } from 'lucide-react';
import type { AppProps } from '../lib/types';

const NOTES_KEY = 'cybexos-demo-notes-v1';
const INITIAL_NOTE = `# A little space to think.

Welcome to Omawrite. A quiet place for words, ideas,
and whatever comes next.

## Make yourself at home

- Explore the desktop.
- Find a theme that feels like you.
- Leave yourself a note.

Your writing stays in this browser. Download a copy
whenever you want to take it with you.

---

What will you make today?
`;

// Only a small, text-only Markdown subset is rendered; no HTML is interpreted.
function MarkdownPreview({ text }: { text: string }) {
  return <div className="notes-rendered">{text.split('\n').map((line, index) => {
    if (line.startsWith('### ')) return <h3 key={index}>{line.slice(4)}</h3>;
    if (line.startsWith('## ')) return <h2 key={index}>{line.slice(3)}</h2>;
    if (line.startsWith('# ')) return <h1 key={index}>{line.slice(2)}</h1>;
    if (/^\s*---+\s*$/.test(line)) return <hr key={index} />;
    if (line.startsWith('- ')) return <p className="notes-list-line" key={index}><span aria-hidden="true">•</span>{line.slice(2)}</p>;
    return line.trim() ? <p key={index}>{line}</p> : <div className="notes-paragraph-space" key={index} />;
  })}</div>;
}

export function NotesApp({ notify }: AppProps) {
  const [text, setText] = useState(INITIAL_NOTE);
  const [loaded, setLoaded] = useState(false);
  const [saved, setSaved] = useState(false);
  const [storageError, setStorageError] = useState('');
  const [preview, setPreview] = useState(false);
  const textarea = useRef<HTMLTextAreaElement>(null);

  useEffect(() => {
    // Read after hydration so server markup and the initial client render agree.
    const frame = requestAnimationFrame(() => {
      try {
        const stored = localStorage.getItem(NOTES_KEY);
        const initial = stored ?? INITIAL_NOTE;
        setText(initial);
        localStorage.setItem(NOTES_KEY, initial);
        setSaved(true);
      } catch {
        setStorageError('Browser storage is unavailable. Download a copy to keep your writing.');
      }
      setLoaded(true);
    });
    return () => cancelAnimationFrame(frame);
  }, []);

  const updateText = (value: string) => {
    setText(value);
    try {
      localStorage.setItem(NOTES_KEY, value);
      setSaved(true);
      setStorageError('');
    } catch {
      setSaved(false);
      setStorageError('Your changes could not be saved in this browser. Download a copy to keep them.');
    }
  };

  const download = () => {
    const blob = new Blob([text], { type: 'text/markdown;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url; link.download = 'My-notes.md';
    document.body.appendChild(link);
    link.click(); link.remove();
    window.setTimeout(() => URL.revokeObjectURL(url), 1000);
    notify('Your notes are ready to download.');
  };

  const insert = (before: string, after = '') => {
    const editor = textarea.current;
    if (!editor) return;
    const start = editor.selectionStart;
    const end = editor.selectionEnd;
    const next = `${text.slice(0, start)}${before}${text.slice(start, end)}${after}${text.slice(end)}`;
    updateText(next);
    requestAnimationFrame(() => { editor.focus(); editor.setSelectionRange(start + before.length, end + before.length); });
  };
  const words = text.trim() ? text.trim().split(/\s+/).length : 0;

  return <div className="notes-app">
    <div className="notes-toolbar app-copy">
      <div className="notes-document"><FileText size={16} /><span>My notes.md</span><span className="notes-document-format">Markdown</span></div>
      <div className="notes-actions"><button className={preview ? 'is-active' : ''} onClick={() => setPreview((value) => !value)} aria-label={preview ? 'Edit note' : 'Preview note'} title={preview ? 'Edit note' : 'Preview note'} aria-pressed={preview}>{preview ? <Pencil size={15} /> : <Eye size={15} />}<span>{preview ? 'Edit' : 'Preview'}</span></button><button onClick={download} aria-label="Download notes" title="Download notes"><Download size={15} /></button></div>
    </div>
    {storageError && <div className="notes-storage-error app-copy" role="alert"><AlertCircle size={16} /><span>{storageError}</span></div>}
    {!preview && <div className="notes-formatting app-copy" role="toolbar" aria-label="Markdown formatting"><button onClick={() => insert('# ')} aria-label="Insert heading" title="Insert heading">H<span>1</span></button><button onClick={() => insert('- ')} aria-label="Insert list item" title="Insert list item">≡</button><button onClick={() => insert('---\n')} aria-label="Insert divider" title="Insert divider">—</button><span>Plain words. Clear thoughts.</span></div>}
    <div className="notes-writing-area">{preview ? <MarkdownPreview text={text} /> : <textarea ref={textarea} aria-label="Note content" spellCheck readOnly={!loaded} value={text} onChange={(event) => updateText(event.target.value)} placeholder="Start writing…" />}</div>
    <footer className="notes-status app-copy"><span>{storageError ? <><AlertCircle size={12} /> Not saved</> : saved ? <><Check size={12} /> Saved in this browser</> : 'Opening note…'}</span><span>{words} words <i>·</i> {text.length} characters</span></footer>
  </div>;
}
