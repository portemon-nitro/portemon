# game/hgss Agent Guidance

Read root `AGENTS.md` and `game/AGENTS.md` first. `game/hgss` is the concrete
HeartGold/SoulSilver application package: it composes reusable HGSS mechanisms into the
playable product.

## Application ownership

- `game/hgss/src/HgssGame.lua` is the concrete HGSS game entry. It creates the generic
  `game.src.Game` host and installs the HGSS states and services for one selected version.
- This package owns HGSS retail application composition for explicit Continue or New Game
  entry, Professor Oak's intro, field entry, retail-specific UI, and application audio. The
  product startup Main Menu belongs to `app`; returning to it is an app-owned route.
- `field/` owns the HGSS `FieldRuntime`/`FieldState` application composition; its
  `FieldSession` remains the reusable field-simulation mechanism in `libs/hgss` and is not
  the game entry point.
- `newgame/` and `audio/` contain application-specific policy or composition. Reusable field,
  script, audio, presentation, and save mechanisms remain in their libraries; reusable
  game-independent widgets belong in `libs/ui`.

## Dependencies and data

- Consume the generic host from `game/src` and reusable contracts/mechanisms from
  `libs/hgss`, `libs/assets`, `libs/storage`, `libs/script`, and foundation packages as
  required by the concrete application.
- Do not import `app`, `romdump`, or `libs/nds` directly. Process callbacks, launcher and
  provisioning policy belong to `app`; ROM/source interpretation belongs to `romdump`; NDS
  implementation details stay behind reusable HGSS-facing seams.
- Nested domain restoration with explicit admission ownership, field-script compatibility,
  HGSS input bindings, and shared presentation mechanisms belong to their libraries.
  Each runtime domain owner restores and checks the nested state it actually uses.
  Application ownership remains here for HGSS retail-specific behavior and composition.
- Existing `data.*` module paths and data layout are unchanged. This package does not own a
  data migration or a cross-game namespace.

## Extension and verification rules

- The package split is an internal ownership boundary, not a public/mod plugin API. Do not
  add a registry, generic Gen-IV framework, or second-game protocol without concrete evidence
  of a shared contract.
- Preserve the current HGSS boot, retail in-game menu, new-game/Oak, continue, field, save,
  input, resize, and shutdown behavior when changing composition. The product startup Main
  Menu is app-owned.
- Unit/component tests live under `game/hgss/tests`; acceptance tests use the real HGSS
  application/field composition when wiring or user-visible sequencing is the contract.
