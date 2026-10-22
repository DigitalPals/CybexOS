import type { Metadata, Viewport } from 'next';
import './globals.css';

export const metadata: Metadata = {
  title: 'NerdOS — Your desktop, in your browser',
  description: 'Experience the NerdOS desktop. Explore workspaces, open apps, try the terminal, and make it yours. No installation needed.',
  icons: {
    icon: [{ url: '/favicon.ico', sizes: '32x32' }, { url: '/favicon.svg', type: 'image/svg+xml' }],
    apple: '/apple-touch-icon.png',
  },
  manifest: '/site.webmanifest',
  openGraph: {
    title: 'NerdOS — The NerdOS desktop, in your browser',
    description: 'Explore the NerdOS desktop: Quickshell controls, Hyprland-style workspaces, wallpapers, and apps.',
    type: 'website',
  },
  twitter: { card: 'summary', title: 'NerdOS — Your desktop, in your browser', description: 'An interactive NerdOS desktop demo. No installation needed.' },
};
export const viewport: Viewport = { width: 'device-width', initialScale: 1, themeColor: '#1A1B1E' };

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en"><body>{children}</body></html>;
}
