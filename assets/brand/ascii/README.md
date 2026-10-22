# NerdOS ASCII logos

Three sizes, all drawn from the same glasses geometry as the graphic logo
(chunky rounded frames, hinge stubs `==`, and the lime repair tape `///` across the bridge).

| File | Size | Use |
|---|---|---|
| `nerdos-compact.txt` | 26 × 4 | narrow terminals, `--logo-type small`-style setups, MOTD one-liners |
| `nerdos-large.txt` | 50 × 7 | default fastfetch logo |
| `nerdos-banner.txt` | 50 × 15 | large logo + wordmark + descriptor (splash, MOTD, installer) |

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
fastfetch --logo ~/.config/fastfetch/nerdos-compact.fastfetch.txt --logo-type file \
          --logo-color-1 '#F3F2EC' --logo-color-2 '#C8FF1F'
```

Hex colours (`#RRGGBB`) need a recent fastfetch; on older builds use the 256-colour codes from the table
(e.g. `--logo-color-2 '38;5;190'`).

## Preview

nerdos-large.txt
```
   .################.     ///.################.
==#######################///####################==
  ####            ######///#####            ####
  ####            #### ///  ####            ####
  ####.          .####//    ####.          .####
  '##################'      '##################'
    '##############'          '##############'
```

nerdos-compact.txt
```
  .######.    //.######.
=############//##########=
 ###    ### // ###    ###
  '######'      '######'
```
