"""NerdOS ASCII logos for fastfetch: plain text + $1/$2 placeholder versions + config + guide."""
import os
OUT = os.path.join(os.environ.get("NERDOS_OUT", "build/nerdos-brand"), "ascii")
os.makedirs(OUT, exist_ok=True)


def build(stub, lens, gap, tape, bridge_rows, stub_rows, stubch="="):
    Lw = len(lens[0])
    out = []
    for r, row in enumerate(lens):
        s = stubch * stub if r in stub_rows else " " * stub
        g = "#" * gap if r in bridge_rows else " " * gap
        line = list(s + row + g + row[::-1] + s)
        for c in tape.get(r, []):
            line[stub + Lw + c] = "/"
        out.append("".join(line).rstrip())
    return out


LARGE_LENS = [
    " .################. ",
    "####################",
    "####            ####",
    "####            ####",
    "####.          .####",
    "'##################'",
    "  '##############'  ",
]
large = build(2, LARGE_LENS, 6, {0: [4, 5, 6], 1: [3, 4, 5], 2: [2, 3, 4], 3: [1, 2, 3], 4: [0, 1]}, {1, 2}, {1})

COMPACT_LENS = [
    " .######. ",
    "##########",
    "###    ###",
    " '######' ",
]
compact = build(1, COMPACT_LENS, 4, {0: [3, 4], 1: [2, 3], 2: [1, 2]}, {1}, {1})

G = {
    "N": ["##.   ##", "###.  ##", "##'#. ##", "## '#.##", "##  '###"],
    "e": ["      ", ".####.", "##__##", "##''''", "'####'"],
    "r": ["     ", "##.##", "###''", "##   ", "##   "],
    "d": ["    ##", ".#####", "##  ##", "##  ##", "'#####"],
    "O": [".######.", "##'  '##", "##    ##", "##.  .##", "'######'"],
    "S": [".######", "##'    ", "'#####.", "    '##", "######'"],
}


def word(text, sp=1, extra=None):
    rows = [""] * 5
    for i, ch in enumerate(text):
        for r in range(5):
            rows[r] += G[ch][r] + ((" " * (sp + (extra or {}).get(i, 0))) if i < len(text) - 1 else "")
    return [x.rstrip() for x in rows]


wm = word("NerdOS", 1, {3: 1})
W = max(len(x) for x in large)
desc = "O P I N I O N A T E D   S Y S T E M"
banner = large + [""] + [" " * ((W - len(wm[0])) // 2) + x for x in wm] + ["", " " * ((W - len(desc)) // 2) + desc]


def placeholders(lines, frame="$1", accent="$2"):
    """Wrap tape runs ('/') in $2 and everything else in $1. Each line starts with $1."""
    out = []
    for l in lines:
        s, cur = "", None
        for ch in l:
            want = accent if ch == "/" else frame
            if ch != " " and want != cur:
                s += want
                cur = want
            s += ch
        out.append(s)
    return out


files = {"nerdos-compact": compact, "nerdos-large": large, "nerdos-banner": banner}
for name, lines in files.items():
    open(f"{OUT}/{name}.txt", "w").write("\n".join(lines) + "\n")
    open(f"{OUT}/{name}.fastfetch.txt", "w").write("\n".join(placeholders(lines)) + "\n")

config = """// NerdOS fastfetch preset — copy to ~/.config/fastfetch/config.jsonc
// Logo files go in ~/.config/fastfetch/ (or adjust "source").
{
  "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
  "logo": {
    "type": "file",                                   // "file" = $1/$2 colour placeholders are replaced
    "source": "~/.config/fastfetch/nerdos-large.fastfetch.txt",
    "color": {
      "1": "#F3F2EC",                                 // frames + lettering: off-white (use "#1A1B1E" on light terminals)
      "2": "#C8FF1F"                                  // tape: electric lime
    },
    "padding": { "top": 1, "left": 2, "right": 4 }
  },
  "display": {
    "separator": "  ",
    "color": { "keys": "#C8FF1F" }
  },
  "modules": [
    "title", "separator", "os", "kernel", "uptime", "packages", "shell",
    "wm", "terminal", "cpu", "gpu", "memory", "disk", "break", "colors"
  ]
}
"""
open(f"{OUT}/fastfetch-config.jsonc", "w").write(config)

readme = f"""# NerdOS ASCII logos

Three sizes, all drawn from the same glasses geometry as the graphic logo
(chunky rounded frames, hinge stubs `==`, and the lime repair tape `///` across the bridge).

| File | Size | Use |
|---|---|---|
| `nerdos-compact.txt` | {max(map(len, compact))} × {len(compact)} | narrow terminals, `--logo-type small`-style setups, MOTD one-liners |
| `nerdos-large.txt` | {max(map(len, large))} × {len(large)} | default fastfetch logo |
| `nerdos-banner.txt` | {max(map(len, banner))} × {len(banner)} | large logo + wordmark + descriptor (splash, MOTD, installer) |

Each comes in two flavours:

* `*.txt` — plain 7-bit ASCII, no colour codes. Use with `"type": "file-raw"` or anywhere else (README, motd, docs).
* `*.fastfetch.txt` — the same art with fastfetch colour placeholders: `$1` = frames and lettering, `$2` = tape.
  Use with `"type": "file"` so the placeholders are replaced.

## Colour guidance

The tape is the only accent. Everything else stays one colour.

| Placeholder | Role | Truecolor | 256-colour fallback | 16-colour fallback |
|---|---|---|---|---|
| `$1` | frames, wordmark (dark terminal) | `#F3F2EC` | `38;5;255` | `bright_white` |
| `$1` | frames, wordmark (light terminal) | `#1A1B1E` | `38;5;234` | `black` |
| `$2` | tape (dark terminal) | `#C8FF1F` | `38;5;190` | `bright_green` |
| `$2` | tape (light terminal) | `#4A7300` | `38;5;64` | `green` |

* On a light terminal background, switch `$1` to charcoal and `$2` to Lime deep: bright lime text
  disappears on white.
* If the terminal can't show colour, leave the art uncoloured: the `/` characters still read as tape
  against the `#` frames.
* Don't recolour the frames lime, and don't use more than these two colours.

## fastfetch

```sh
mkdir -p ~/.config/fastfetch
cp nerdos-*.txt fastfetch-config.jsonc ~/.config/fastfetch/
mv ~/.config/fastfetch/fastfetch-config.jsonc ~/.config/fastfetch/config.jsonc
fastfetch
```

One-off from the command line:

```sh
fastfetch --logo ~/.config/fastfetch/nerdos-compact.fastfetch.txt --logo-type file \\
          --logo-color-1 '#F3F2EC' --logo-color-2 '#C8FF1F'
```

Hex colours (`#RRGGBB`) need a recent fastfetch; on older builds use the 256-colour codes from the table
(e.g. `--logo-color-2 '38;5;190'`).

## Preview

nerdos-large.txt
```
{chr(10).join(large)}
```

nerdos-compact.txt
```
{chr(10).join(compact)}
```
"""
open(f"{OUT}/README.md", "w").write(readme)

if __name__ == "__main__":
    for n, l in files.items():
        print(n, max(map(len, l)), "x", len(l))
        print("\n".join(l))
        print()
    print(open(f"{OUT}/nerdos-compact.fastfetch.txt").read())
