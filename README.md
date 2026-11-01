# Portémon Nitro

[![Join us on Discord](https://img.shields.io/badge/Join%20us%20on-Discord-5865F2?logo=discord&logoColor=white)](https://discord.gg/dGf5K6kcwZ)

Portémon Nitro is an unofficial way to play your Pokémon HeartGold/SoulSilver
copy on PC, mobile, and potentially many other devices. It's a port of the game
engine build with LÖVE that reads your ROM directly, then uses it to run the game.

This project is not an emulator and does not ship copyrighted ROM data,
dialogue, graphics, models, or audio. You must provide your own compatible ROM;
the importer recognizes only the supported canonical US dumps. Your ROM file
stays where you keep it: the app records only a small pointer to it, never a
copy, and derived game data is compiled straight from the original.

## Contributing

Run commands from the repository root (assumes UNIX-like system for most things):

```sh
scripts/run.sh (run.bat on Windows)
scripts/test.sh [--filter <substring>] [--rom-source <path-to-nds-or-zip-file>]
```

### macOS

Install the pinned LÖVE runtime and contributor tools locally, then launch:

```sh
scripts/lib/repo-setup.sh --dev --yes
scripts/run.sh
```

This works with the system Bash on Apple silicon and Intel Macs. Drag your
supported US HeartGold or SoulSilver `.nds` or `.zip` file onto the window to
import it. The native file picker requires the optional bridge described in
[`app/native/README.md`](app/native/README.md).

Development data stays under `.cache/` in the checkout. To run ROM-dependent
tests in their separate private cache:

```sh
scripts/test.sh --rom-source "/absolute/path/to/Pokemon SoulSilver.nds"
scripts/test.sh --self-test
scripts/lint.sh --check
```

macOS tests use a hidden native graphics window and require a logged-in desktop
session. Linux tests use the offscreen software graphics driver.

## Acknowledgements

Portémon Nitro was heavily inspired by the
[G1R Deluxe](https://github.com/bryanthaboi/gen1recomp), and owes a lot to the
incredible work done by the `pret` folks in the [HGSS Decomp](https://github.com/pret/pokeheartgold), as well as the [MelonDS Emulator](https://github.com/melonDS-emu/melonDS) which were used for research.
We are **not** in any way affiliated or associated with any of these projects,
nor with the Pokémon Company or GameFreak.
