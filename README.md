# Portémon Nitro

[![Join us on Discord](https://img.shields.io/badge/Join%20us%20on-Discord-5865F2?logo=discord&logoColor=white)](https://discord.gg/dGf5K6kcwZ)

Portémon Nitro is an unofficial way to play your Pokémon HeartGold/SoulSilver
copy on PC, mobile, and potentially many other devices. It's a port of the game
engine build with LÖVE that extracts the ROM data, then uses it to run the game.

This project is not an emulator and does not ship copyrighted ROM data,
dialogue, graphics, models, or audio. You must provide your own compatible ROM;
the importer recognizes only the supported canonical US dumps.

## Requirements

- [LÖVE 11.5](https://love2d.org/)


## Contributing

Run commands from the repository root (assumes UNIX-like system):

```sh
scripts/run.sh
scripts/test.sh [--rom-source <path-to-nds-or-zip-file>]
scripts/lint.sh          # format Lua, then run fast static/policy checks
```

`lint.sh` needs [StyLua](https://github.com/JohnnyMorganz/StyLua) and
[LuaLS](https://github.com/LuaLS/lua-language-server) on `PATH`.


See [the architecture principles](docs/architecture.md) for ownership,
dependency direction, and data-lifecycle guidance.

## Acknowledgements

Portémon Nitro was heavily inspired by the
[G1R Deluxe](https://github.com/bryanthaboi/gen1recomp), and owes a lot to the
incredible work done by the `pret` folks in the [HGSS Decomp](https://github.com/pret/pokeheartgold), as well as the [MelonDS Emulator](https://github.com/melonDS-emu/melonDS) which were used for research.
We are **not** in any way affiliated or associated with any of these projects,
nor with the Pokémon Company or GameFreak.
