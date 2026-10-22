import { DEMO_SYSTEM, CYBEXOS_LOGO, SYSTEM_DETAILS } from '../lib/terminal';

/** A semantic rendering of the same sample data returned by the command parser. */
export function Fastfetch() {
  return (
    <section className="terminal-fastfetch" aria-label="CybexOS system overview">
      <div className="terminal-cybexos-art" aria-hidden="true">
        <pre>{CYBEXOS_LOGO}</pre>
        <span>cybexos</span>
        <small>Freedom. Friends. Features. First.</small>
      </div>
      <div className="terminal-fetch-info">
        <div className="terminal-fetch-title"><strong>guest</strong><span>@</span><strong>{DEMO_SYSTEM.hostname}</strong></div>
        <div className="terminal-fetch-rule" aria-hidden="true">──────────────────────────</div>
        <dl>{SYSTEM_DETAILS.map(([label, value]) => <div key={label}><dt>{label}</dt><dd>{value}</dd></div>)}</dl>
        <div className="terminal-swatches" aria-label="Terminal color palette">
          {Array.from({ length: 16 }, (_, index) => <i key={index} className={`terminal-color-${index % 8}${index >= 8 ? ' terminal-color-bright' : ''}`} />)}
        </div>
        <p className="terminal-fixture-note">Demo system information · sample hardware &amp; packages</p>
      </div>
    </section>
  );
}
