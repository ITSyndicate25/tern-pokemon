# Tern Pokémon

A [Tern](https://stencil.so/tern) plugin that ports
[jakobhoeg/vscode-pokemon](https://github.com/jakobhoeg/vscode-pokemon) to a
pane: Pokémon walk, sit and get petted on a beach, forest or castle, drawn
natively by Tern — animated GIF sprites, no web view, no browser.

Open it from the palette (**New Pokémon block**); each pane holds up to 8
Pokémon, and several panes can run side by side.

## Requirements

- Tern with plugin image blobs (0.5.3 or newer): plugin `image` nodes draw
  animated GIF, APNG and WebP blobs, which is what the sprites are.

## Install

```sh
tern plugin install github.com/ITSyndicate25/tern-pokemon
```

While developing, load it from a checkout instead:

```sh
git clone https://github.com/ITSyndicate25/tern-pokemon
tern plugin link ./tern-pokemon
```

## Controls

| Button | Key | Does |
| --- | --- | --- |
| `+` | — | Pick a Pokémon to add (search sheet: type, `↑`/`↓`, `Enter`) |
| — | `n` / `+` | Add a random Pokémon |
| shuffle | `r` | Shuffle: every Pokémon becomes a new random one |
| trash | `x` / `delete` | Remove the last Pokémon; on an empty pane, close it |
| sparkle | `s` | Force shiny (or back to normal colours) |
| image | `t` | Cycle scene: beach → forest → castle → none |
| sun/moon | `d` | Light or dark background |
| — | click a sprite | Pet it: a heart pops over its head |

Species, scene, colours and positions survive pane restarts and daemon
reloads through the block's saved state.

## How it draws

The scene is one `image` node (the extension's 1422×800 background) inside a
56.25% aspect stage, with one absolutely positioned row per Pokémon over it —
flex spacers place each sprite at its x — and the foreground image last, so
feet stand behind the sand. Sprites are the extension's GIFs
(`{default,shiny}_{idle,walk,walk_left}_8fps.gif`), shown at 2× their native
size with `image-rendering: pixelated`.

A 100 ms tick runs the extension's state machine: sit ~5–8 s (`idle`), then
walk left or right for up to 6 s (`walk`, or `walk_left` where the species
has one, else mirrored with `scaleX(-1)`), stopping at the edges, on a 1%
per-tick chance, or after 60 ticks — walk speed 3 px/tick ±30%, as in
`PokemonSpeed.normal`. Spawning rolls shiny at 1 in 8192
(`vscode-pokemon.shinyOdds`).

## Assets and licence

This repository ships **no game artwork**. Sprites, backgrounds, foregrounds
and the heart are downloaded on first use from the
[vscode-pokemon](https://github.com/jakobhoeg/vscode-pokemon) repository, then
kept as files in this plugin's data directory (`cache/`, under Tern's state
directory); each pane replays them into Tern's content-addressed blob store,
so later panes and restarts draw them with no network.

`data/pokemon.luau` lists the 632 spawnable species (name, Pokédex number,
generation, shiny and left-facing sprite availability, native size).
Regenerate it after a vscode-pokemon update:

```sh
python tools/gen-data.py /path/to/vscode-pokemon
```

Pokémon and Pokémon character names are trademarks of Nintendo; the artwork
is © The Pokémon Company, redistributed by the vscode-pokemon project for
non-commercial use. The plugin's own code is MIT-licensed ([LICENSE](LICENSE)).
