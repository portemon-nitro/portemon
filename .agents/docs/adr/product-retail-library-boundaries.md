# ADR: Product, retail-game, and reusable-library boundaries

**Status:** Accepted
**Date:** 2026-10-01
**Scope:** Ownership boundaries between Portemon product behavior, retail-game reproduction,
reusable mechanisms, and ROM/source production.

**Supersedes:** [Application and game boundaries](application-game-boundaries.md)

## Context

The earlier application/game split grouped Portemon-created Main Menu behavior with the
retail HGSS application and kept reusable HGSS save semantics inside `game/hgss`.
That obscured where a future save editor belongs and made product UX depend on retail
internals. Shared presentation mechanisms also lived with HGSS consumers even though they
express host display facts and layout geometry.

These distinctions matter for product work such as a future save editor and for a future
second retail family such as DPP. Neither is an implemented feature. The repository already
has separate owners for application composition, reusable runtime mechanisms, and source
production, so clarifying their responsibilities is lower cost than adding another package
or framework.

## Decision

Classify behavior by why it exists and the lowest reusable owner that can express it without
upward dependencies. A caller's current directory is not evidence of ownership.

- `app` owns Portemon-created product behavior and process composition, including the
  selected-version startup Main Menu and future product tooling such as a save editor. It may
  consume reusable libraries allowed by the architecture gate.
- `game/src` owns the thin game-agnostic running-game host and adapters. `game/<family>` owns
  observable retail-game reproduction and application composition. HGSS enters through an
  explicit `HgssGame` New Game or Continue choice; product menu ownership remains in `app`.
- `libs/<domain>` owns reusable domain and runtime mechanisms. These may remain specific to
  one game where their semantics are game-specific: complete HGSS save compatibility and
  HGSS input/script semantics belong in `libs/hgss`, while shared widgets and presentation
  mechanisms belong in `libs/ui`.
- `romdump` owns ROM/decomp interpretation and generated-artifact production.

DPP should receive its own retail package if implemented. Extract shared mechanisms only
when concrete duplication or a current shared contract establishes the need. Do not create a
generic Gen-IV framework or game registry in anticipation.

This ADR supersedes [Application and game boundaries](application-game-boundaries.md) only
for the product/retail/reusable ownership split. The reusable runtime package decisions in
[runtime package boundaries](runtime-package-boundaries.md) remain accepted.

## Alternatives considered

- Keep the startup Main Menu in `game/hgss`: rejected because Portemon creates that product
  UX; the retail game begins when the user selects an explicit entry route.
- Collapse game into `app`: rejected because the running-game host and retail application
  have distinct lifecycle and ownership responsibilities.
- Move every HGSS-aware product behavior into the retail package: rejected because reusable
  HGSS semantics can serve `app`-owned product features without transferring retail ownership.
- Create a generic Gen-IV package or game registry now: rejected because no second retail
  family currently establishes a shared contract.

## Consequences

The startup menu and future save editor have a product owner, retail screens remain with
their game family, and reusable HGSS semantics can serve more than one current layer. The
explicit entry choice makes the handoff to `HgssGame` clear. The architecture test remains
the authority for concrete import legality; role guidance does not grant arbitrary
dependencies.

This decision defines no save-editor or DPP implementation, generic multi-game interface,
or new plugin surface.

## Revisit when

Revisit when a second retail family is implemented and exposes a concrete shared product or
entry contract, or when a current `app`-owned tool needs reusable semantics that cannot fit the
existing dependency graph.
