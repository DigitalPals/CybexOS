import type { Metadata, Viewport } from 'next';
import './globals.css';

export const metadata: Metadata = {
  title: 'Cybex OS — Your desktop, in your browser',
  description: 'Experience the Cybex OS desktop. Explore workspaces, open apps, try the terminal, and make it yours. No installation needed.',
  icons: {
    icon: [{ url: '/favicon.ico', sizes: '32x32' }, { url: '/favicon.svg', type: 'image/svg+xml' }],
    apple: '/apple-touch-icon.png',
  },
  manifest: '/site.webmanifest',
  openGraph: {
    title: 'Cybex OS — The Cybex OS desktop, in your browser',
    description: 'Explore the Cybex OS desktop: Quickshell controls, Hyprland-style workspaces, wallpapers, and apps.',
    type: 'website',
  },
  twitter: { card: 'summary', title: 'Cybex OS — Your desktop, in your browser', description: 'An interactive Cybex OS desktop demo. No installation needed.' },
};
export const viewport: Viewport = { width: 'device-width', initialScale: 1, themeColor: '#1A1B1E' };

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en"><body>{children}</body></html>;
}
