'use client';

import { useState } from 'react';
import { ArrowRight, CalendarDays, ChevronLeft, ChevronRight, X } from 'lucide-react';
import { Overlay } from './Overlay';

interface CalendarPanelProps {
  now: Date;
  clock24: boolean;
  close: () => void;
}

function dateKey(date: Date) {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
}

export function CalendarPanel({ now, clock24, close }: CalendarPanelProps) {
  const [view, setView] = useState(() => new Date(now.getFullYear(), now.getMonth(), 1));
  const today = dateKey(now);
  const firstWeekday = (view.getDay() + 6) % 7;
  const daysInMonth = new Date(view.getFullYear(), view.getMonth() + 1, 0).getDate();
  const week = Array.from({ length: 7 }, (_, index) => {
    const day = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    day.setDate(day.getDate() - (day.getDay() + 6) % 7 + index);
    return day;
  });
  const timeParts = new Intl.DateTimeFormat([], {
    hour: '2-digit', minute: '2-digit', hour12: !clock24,
  }).formatToParts(now);
  const time = timeParts.filter(part => part.type !== 'dayPeriod').map(part => part.value).join('').trim();
  const period = timeParts.find(part => part.type === 'dayPeriod')?.value;
  const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone.replaceAll('_', ' ');

  function changeMonth(offset: number) {
    setView(current => new Date(current.getFullYear(), current.getMonth() + offset, 1));
  }

  return <Overlay label="Calendar" className="day-sheet" close={close}>
    <div className="day-sheet-overview">
      <div className="day-sheet-clock">
        <time dateTime={now.toISOString()} className="day-sheet-time">{time}{period && <span>{period}</span>}</time>
        <p>{now.toLocaleDateString([], { weekday: 'long', day: 'numeric', month: 'long' })}</p>
      </div>
      <div className="day-sheet-week" aria-label="This week">
        {week.map(day => <time key={dateKey(day)} dateTime={dateKey(day)} aria-current={dateKey(day) === today ? 'date' : undefined}
          className={dateKey(day) === today ? 'is-today' : ''}
          aria-label={day.toLocaleDateString([], { weekday: 'long', day: 'numeric', month: 'long' })}>
          <span>{day.toLocaleDateString([], { weekday: 'short' })}</span>
          <strong>{day.getDate()}</strong>
          <i aria-hidden="true" />
        </time>)}
      </div>
    </div>

    <div className="day-sheet-body">
      <section className="day-sheet-month" aria-label="Month calendar">
        <div className="day-sheet-month-heading">
          <h2 aria-live="polite">{view.toLocaleDateString([], { month: 'long', year: 'numeric' })}</h2>
          <div className="day-sheet-month-actions">
            <button aria-label="Previous month" onClick={() => changeMonth(-1)}><ChevronLeft size={16} /></button>
            <button aria-label="Next month" onClick={() => changeMonth(1)}><ChevronRight size={16} /></button>
          </div>
        </div>
        <div className="day-sheet-month-grid">
          {week.map(day => <span className="day-sheet-weekday" key={`weekday-${day.getDay()}`}>
            {day.toLocaleDateString([], { weekday: 'short' })}
          </span>)}
          {Array.from({ length: firstWeekday }, (_, index) => <span key={`offset-${index}`} aria-hidden="true" />)}
          {Array.from({ length: daysInMonth }, (_, index) => {
            const day = new Date(view.getFullYear(), view.getMonth(), index + 1);
            const current = dateKey(day) === today;
            return <time key={index} dateTime={dateKey(day)} className={current ? 'is-today' : ''}
              aria-current={current ? 'date' : undefined}>{index + 1}</time>;
          })}
        </div>
      </section>

      <section className="day-sheet-agenda" aria-label="Upcoming events">
        <h2>Upcoming</h2>
        <div className="day-sheet-empty">
          <CalendarDays size={23} strokeWidth={1.5} aria-hidden="true" />
          <p>No events in this browser preview</p>
        </div>
      </section>
    </div>

    <footer className="day-sheet-footer">
      <button className="day-sheet-today" onClick={() => setView(new Date(now.getFullYear(), now.getMonth(), 1))}>
        Back to today<ArrowRight size={13} />
      </button>
      <span title="Browser time zone">{timeZone}</span>
      <button className="day-sheet-close" aria-label="Close calendar" onClick={close}><X size={16} /></button>
    </footer>
  </Overlay>;
}
