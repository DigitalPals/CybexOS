# Welcome guide assets

| Asset | Source | Treatment |
|---|---|---|
| `cybexos-logo.svg` | `assets/brand/logo/svg/cybexos-logo-on-dark.svg`, also the installer's `installer/kiosk/assets/logo.svg` | Unchanged copy. The guide's top bar draws the wordmark the installer shows; `welcome-kiosk.test.cjs` keeps the two files equal. |

The wordmark is the operating system's own logo, not a product identity, so
it stays out of `../../assets`, whose files are the `BrandIcons` registry.
