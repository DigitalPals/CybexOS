'use client';

import { useState } from 'react';
import { ArrowLeft, ArrowUp, ChevronRight, Code2, Download, FileText, Folder, Grid2X2, HardDrive, House, ImageIcon, List, Search, StickyNote, X } from 'lucide-react';
import type { AppProps } from '../lib/types';
import { displayPath, FILE_SYSTEM, HOME_PATH } from '../lib/terminal';
import type { VirtualFile } from '../lib/terminal';

const places = [
  { name: 'Home', icon: House, path: HOME_PATH },
  { name: 'Documents', icon: FileText, path: `${HOME_PATH}/Documents` },
  { name: 'Downloads', icon: Download, path: `${HOME_PATH}/Downloads` },
  { name: 'Pictures', icon: ImageIcon, path: `${HOME_PATH}/Pictures` },
  { name: 'Code', icon: Code2, path: `${HOME_PATH}/Code` },
];

export function FilesApp({ openApp }: AppProps) {
  const [path, setPath] = useState(HOME_PATH);
  const [backStack, setBackStack] = useState<string[]>([]);
  const [query, setQuery] = useState('');
  const [view, setView] = useState<'grid' | 'list'>('grid');
  const [preview, setPreview] = useState<VirtualFile | null>(null);
  const files = FILE_SYSTEM[path] ?? [];
  const filtered = files.filter((file) => file.name.toLowerCase().includes(query.toLowerCase()));
  const relativeParts = path === HOME_PATH ? [] : path.slice(HOME_PATH.length + 1).split('/');

  const navigate = (next: string) => {
    if (next !== path) setBackStack((previous) => [...previous, path]);
    setPath(next); setQuery(''); setPreview(null);
  };
  const goBack = () => {
    if (preview) { setPreview(null); return; }
    if (!backStack.length) return;
    setPath(backStack[backStack.length - 1]);
    setBackStack((previous) => previous.slice(0, -1));
    setQuery('');
  };
  const openFile = (file: VirtualFile) => {
    if (file.kind === 'folder') navigate(`${path}/${file.name}`);
    else if (file.kind === 'note') openApp('notes');
    else setPreview(file);
  };

  return <div className="files-app app-copy">
    <div className="files-toolbar">
      <div className="files-navigation">
        <button className="files-icon-button" aria-label="Go back" title="Go back" disabled={!backStack.length && !preview} onClick={goBack}><ArrowLeft size={16} /></button>
        <button className="files-icon-button" aria-label="Parent folder" title="Parent folder" disabled={path === HOME_PATH} onClick={() => navigate(path.slice(0, path.lastIndexOf('/')))}><ArrowUp size={16} /></button>
      </div>
      <nav className="files-breadcrumbs" aria-label="Folder path">
        <button onClick={() => navigate(HOME_PATH)}><House size={13} /><span>Home</span></button>
        {relativeParts.map((part, index) => <span key={part} className="files-crumb"><ChevronRight size={12} /><button onClick={() => navigate(`${HOME_PATH}/${relativeParts.slice(0, index + 1).join('/')}`)}>{part}</button></span>)}
      </nav>
      <div className="files-view-toggle" role="group" aria-label="File view">
        <button className="files-icon-button" aria-label="Grid view" title="Grid view" aria-pressed={view === 'grid'} onClick={() => setView('grid')}><Grid2X2 size={15} /></button>
        <button className="files-icon-button" aria-label="List view" title="List view" aria-pressed={view === 'list'} onClick={() => setView('list')}><List size={16} /></button>
      </div>
    </div>
    <div className="files-body">
      <aside className="files-sidebar" aria-label="Places">
        <div className="files-sidebar-label">Places</div>
        {places.map((place) => <button key={place.path} className={path === place.path ? 'is-active' : ''} onClick={() => navigate(place.path)} aria-current={path === place.path ? 'location' : undefined}><place.icon size={16} /><span>{place.name}</span></button>)}
        <div className="files-sidebar-bottom"><HardDrive size={15} /><div>Browser preview<span>Sample filesystem</span></div></div>
      </aside>
      <main className="files-main">
        {preview ? <div className="files-preview">
          <div className="files-preview-heading"><span><FileText size={16} />{preview.name}</span><button className="files-icon-button" onClick={() => setPreview(null)} aria-label="Close file preview"><X size={16} /></button></div>
          {preview.kind === 'image' ? <div className="files-image-preview"><img src="/wallpapers/moon-mountains-1280.webp" srcSet="/wallpapers/moon-mountains-1280.webp 1280w, /wallpapers/moon-mountains-2560.webp 2560w, /wallpapers/moon-mountains-5120.webp 5120w" sizes="(max-width: 760px) 100vw, 900px" alt="A moon above an atmospheric mountain landscape, the CybexOS desktop wallpaper" /><p>The view from your desktop.</p></div> : <pre className="files-text-preview">{preview.content}</pre>}
        </div> : <>
          <div className="files-folder-heading"><div><h2>{path === HOME_PATH ? 'Home' : relativeParts[relativeParts.length - 1]}</h2><p>{path === HOME_PATH ? 'A place for your things.' : displayPath(path)}</p></div><label className="files-search"><Search size={15} /><input aria-label="Search this folder" placeholder="Search folder" value={query} onChange={(event) => setQuery(event.target.value)} />{query && <button aria-label="Clear file search" onClick={() => setQuery('')}><X size={13} /></button>}</label></div>
          {filtered.length ? <div className={`files-items files-items-${view}`} aria-label="Files and folders">
            {filtered.map((file) => <button key={file.name} className={`files-item files-kind-${file.kind}`} onClick={() => openFile(file)} aria-label={`Open ${file.name}`}>
              <span className="files-item-art">{file.kind === 'folder' ? <Folder size={48} strokeWidth={1.3} /> : file.kind === 'image' ? <img src="/wallpapers/moon-mountains-1280.webp" alt="" /> : file.kind === 'note' ? <StickyNote size={39} strokeWidth={1.3} /> : <FileText size={39} strokeWidth={1.3} />}</span>
              <span className="files-item-name">{file.name}</span><span className="files-item-description">{file.description}</span>
              {view === 'list' && <ChevronRight className="files-item-arrow" size={14} />}
            </button>)}
          </div> : <div className="files-empty"><Folder size={40} strokeWidth={1} /><h3>{query ? 'No matching files' : 'A little room to breathe.'}</h3><p>{query ? `Nothing in this folder matches “${query}”.` : 'This sample folder is empty.'}</p>{query && <button onClick={() => setQuery('')}>Clear search</button>}</div>}
        </>}
      </main>
    </div>
    <footer className="files-status"><span>{preview ? preview.name : `${filtered.length} ${filtered.length === 1 ? 'item' : 'items'}`}</span><span>Sample files · stored in this experience</span></footer>
  </div>;
}
