# Architecture

portemon separates source knowledge, generated contracts, reusable runtime
mechanisms, and product composition. The boundaries keep ROM-specific facts
out of runtime code and keep saves independent from rebuildable assets.

## Dependency direction

Dependencies point from consumer to dependency. The architecture test enforces
this positive package graph and rejects unknown first-party targets:

```text
libs/assets ──► codec, errors, math
libs/mons ────► assets, codec, errors, math
libs/items ───► assets, errors
libs/nds ─────► codec, errors, math
libs/script ──► assets, codec, errors, math, storage
libs/hgss ────► nds, script, assets, codec, errors, math, storage
libs/ui ──────► (leaf, no first-party dependencies)
romdump ──────► nds, script, assets, codec, errors, math, storage
game ─────────► codec, errors, math, storage
game/hgss ────► game, hgss, ui, assets, script, mons, items, codec, errors, math, storage
app ──────────► game, game/hgss, hgss, ui, storage, errors
app ── provisioning only ──► romdump
```

The directory of the current caller does not determine ownership. Classify by why behavior
exists and the lowest reusable owner that can express it without upward dependencies:
Portemon-created product behavior belongs in `app`; retail-game behavior belongs in
`game/<family>`; reusable mechanisms belong in `libs/<domain>`; source interpretation and
derived-asset production belong in `romdump`. The concrete dependency graph remains enforced
by the architecture test; these role descriptions do not preauthorize new edges.

`game/src` is the thin game-agnostic host. It must not import `app`, `game/hgss`,
`libs/hgss`, `libs/nds`, or `romdump`. `game/hgss` is the concrete HGSS retail application
and must not import `app`, `romdump`, or `libs/nds`. `app` owns the only runtime path that
reaches `romdump`, and only for ROM provisioning. It also consumes the reusable HGSS, UI,
and storage libraries currently admitted by the architecture gate.

## Ownership

| Area | Owner | Contract |
| --- | --- | --- |
| Product process and UX | `app/` | LÖVE callbacks, launcher, startup Main Menu, version selection, file drops, cache routing, product tooling, and process exit |
| Generic game host | `game/src/` | state lifecycle, game host adapters, resize, input forwarding, and exit notification |
| HGSS retail application | `game/hgss/` | explicit New Game/Continue entry, Oak, field composition, retail UI, and application audio |
| HGSS mechanisms | `libs/hgss/` | reusable field, script compatibility, audio, input, and save behavior |
| Shared widgets and presentation | `libs/ui/` | game-independent widgets, display facts, and shared presentation mechanisms |
| Mod scripting | `libs/script/` | the `gen4.script` runtime, composition, scheduling, and persistence |
| Nintendo formats | `libs/nds/` | reusable DS, Nitro, NNS, graphics, and renderer mechanisms |
| Asset contracts | `libs/assets/` | generated schemas, cache paths/readiness, validation, and mod-facing text forms |
| Items domain | `libs/items/` | item identity and Bag-relevant metadata |
| Mon domain | `libs/mons/` | semantic mon records, parties, Generation-IV creation/legality/codec, and the mons save bucket |
| Source digestion | `romdump/` | ROM access, NARC/HGSS interpretation, provenance, and derived-asset production |

Source-specific parsing belongs in `romdump`, even when pure. A structure
belongs in `libs/assets` only when a custom producer or consumer can use it
without understanding the source ROM. Runtime code consumes the resulting
contract; it does not parse NARC members, ROM bytes, overlays, or retail ROM
references.

Generic binary, storage, error, and mathematical primitives stay in their
focused libraries; repository-root reads belong to `libs/storage`. New shared APIs and extension points need a current
consumer; hypothetical future mods do not establish ownership.

## Repository shape

```text
app/          interactive LÖVE shell, product Main Menu, and tooling (`love app/`)
game/src/     thin generic running-game host and adapters
game/hgss/    concrete HeartGold/SoulSilver retail application
romdump/      source ingestion and asset production (`love romdump/`)
libs/assets/  generated and mod-facing contracts
libs/items/   item identity and metadata
libs/mons/    semantic mon/party domain and Generation-IV representation
libs/codec/   serialization primitives
libs/storage/ cache, save, and staged publication
libs/errors/  structured errors
libs/math/    fixed-point and matrix primitives
libs/nds/     Nintendo DS/Nitro/NNS mechanisms
libs/script/  mod scripting platform
libs/hgss/    recreated HGSS mechanisms
data/         game-owned manifests and scripts
tests/        runner, ROM, acceptance, and graphics suites
```

The entrypoints are `app/main.lua`, `romdump/main.lua`, `app/src/App.lua`,
`game/src/Game.lua`, and `game/hgss/src/HgssGame.lua`. Modules use full
repo-relative require paths. Tests live beside their owner; the shared runner
and architecture gates live under `tests/`.

## Runtime and data lifecycle

The app records a small binding to the user's own ROM file, then every
selection waits for source readiness before entering its product Main
Menu. A current complete derived cache boots and plays without touching
the ROM; an incomplete cache stays on a boot-only source prompt until
its exact ROM is verified, even when its bounded opening closure is
ready. Once admitted, gameplay never asks for the ROM again: background
warmup continues in the retained session, and unexpected runtime damage
is a cache failure, not a mid-game source request. The menu routes an
explicit New Game or Continue selection
to `HgssGame`, which creates the generic `Game` host and installs the
corresponding HGSS retail flow. The ROM itself is never copied into managed
storage; compilers read it directly on a genuine cache miss over one shared
in-memory source, and a complete cache boots and plays without touching it:

```text
user-owned ROM → per-version source binding → direct source reads
                                                       ↓
                         permanently retained compact derived assets
                                                       ↓
                         app Main Menu → HgssGame → game/hgss runtime
```

Import verifies the ROM before recording its binding. Derived builds stage,
validate, and publish complete trees; markers are written last. A failed
replacement leaves the last ready artifact usable. Generated cache data and
persistent saves use separate namespaces. The full warmed corpus is kept
indefinitely with no eviction; superseded outputs are retired only with
proof, never by quota.

`game/hgss` owns retail application composition. Its `FieldRuntime` owns the
non-rendering field session, maps, actors, scripts, input, transitions, saves,
and deterministic camera state. `FieldState` owns the LÖVE presentation and
GPU resources. Reusable field simulation and HGSS mechanisms remain in
`libs/hgss`; the generic `Game` lifecycle remains in `game/src`.

## Asset and mod boundary

`romdump` turns source structures into project-owned assets. `libs/assets`
exposes those assets as stable, source-independent data: for example, message
records carry display text, tokens, and metadata rather than code units or
source offsets. The runtime renders and formats that contract. Physical IDs,
paths, offsets, packing, and retail ROM catalogs remain producer-side unless
a product feature gives one semantic meaning.

Derived assets are stored compactly but read back byte-identical, versioned
independently from the user's ROM. A coarse logical cache generation — the
development producer-byte digest or the explicit per-game release counter —
together with the asset-contract identity determines whether a full rebuild
is needed; per-artifact completion markers repair missing derived classes
without touching the source. The user-supplied ROM stays the user's file:
it is never modified, moved, or redistributed, and no derived artifact may
stand in for it where provenance matters.

## ID namespaces

These indices are unrelated and must remain named by kind:

| Name | Meaning |
| --- | --- |
| `narcId` | HGSS NARC catalog index (retail ROM) |
| `fileId` | NDS cartridge FAT index |
| `memberId` | NARC member FAT index |

Paths resolve through the ROM's FNT/FAT, while catalog names provide semantic
source labels. IDs and offsets are zero-based.

For dual-screen adaptation policy, see [`.agents/docs/presentation-layout.md`](../.agents/docs/presentation-layout.md).
For cache and publication failure rules, see [`.agents/docs/defensive-patterns.md`](../.agents/docs/defensive-patterns.md).
