# libs/hgss Agent Guidance

Read root `AGENTS.md` first. `libs/hgss` owns recreated HeartGold/SoulSilver runtime
mechanisms and presents HGSS-facing seams to the application layer.

## Domain organization

Keep reviewer-facing mechanisms in these shallow domain subpackages:

- `field` — deterministic session/application coordination, input, camera, field
  applications, shared errors/IDs, and services that coordinate sibling domains.
- `actors` — field actor/player identity, movement, autonomy, and actor definitions.
- `world` — maps, cells, residency, collision, terrain, zones, weather, and world facts.
- `interaction` — event, message, signpost, choice, and interaction resolution.
- `transition` — warps, doors, fades, entrances, and field transition semantics.
- `script` — HGSS value/reference semantics, field-shaped script adapters, and field-script
  compatibility.
- `audio` — HGSS audio policy composed over the NDS sound mechanisms.
- `presentation` — field scene, camera, queue, and presentation composition.
- `ui` — reusable HGSS runtime UI mechanisms, including HGSS input-binding authority;
  game-independent widgets and shared presentation mechanisms belong in `libs/ui`.
- `save` — HGSS save schema, envelope normalization, supported migrations,
  and persistence. Each runtime domain owner restores and checks the nested
  state it actually uses; there is no whole-save semantic preflight.
- `items` — HGSS Bag inventory mechanics, field cursor, and the live Bag service.
- `mons` — the HGSS-facing live mon/party service over the domain package; follower
  field coordination stays in `field`.

These are semantic siblings inside `libs/hgss` because the mechanisms are HGSS-specific;
do not create a generic `libs/field` package. Cross-domain coordination belongs in
`field`, not in a new catch-all or technical-layer directory. Presentation renderers
remain in `presentation` even when they draw actors or field effects.

HGSS may consume `libs/nds`, `libs/script`, `libs/assets`, and foundation libraries when
those mechanisms are part of a concrete runtime responsibility. It must not import
`romdump` or own application policy.

Both `app` and `game/hgss` may consume these reusable HGSS-specific semantics where the
architecture gate permits the dependency. Their use does not transfer product or retail
application ownership into this library.

## Application boundary

Launcher state, the product startup Main Menu, LÖVE process composition, version selection,
ROM provisioning, and process exit policy belong to `app`.
Retail story flow, explicit new-game sequencing, Professor Oak intro policy, field application
composition, and application audio belong to the concrete `game/hgss` package. Field-script
compatibility and HGSS input semantics remain reusable mechanisms
here. Do not move application policy into this library merely because it invokes a reusable
HGSS mechanism.
The generic running-game lifecycle and host adapters belong to `game`; `FieldSession` is a
field-simulation mechanism, not a game entry point.
