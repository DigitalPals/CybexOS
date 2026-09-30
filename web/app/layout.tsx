import type { Metadata, Viewport } from 'next';
import './globals.css';

export const metadata: Metadata = {
  title: 'CybexOS — Your desktop, in your browser',
  description: 'Experience the CybexOS desktop. Explore workspaces, open apps, try the terminal, and make it yours. No installation needed.',
  icons: { icon: '/cybex-wordmark.svg' },
  openGraph: {
    title: 'CybexOS — A little less friction. A lot more flow.',
    description: 'Try the CybexOS desktop in your browser. Five workspaces. Your colors. Room to think.',
    type: 'website',
  },
  twitter: { card: 'summary', title: 'CybexOS — Your desktop, in your browser', description: 'An interactive CybexOS desktop demo. No installation needed.' },
};
export const viewport: Viewport = { width: 'device-width', initialScale: 1, themeColor: '#1a1917' };

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en"><body>{children}</body></html>;
}
