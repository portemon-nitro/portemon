# libs/content Agent Guidance

Read root `AGENTS.md` first. `libs/content` owns startup-only ordered
composition of contributed definitions plus frozen semantic lookup. It is
pure Lua with no LÖVE, source ROM, game, battle, mon, item, or presentation
knowledge.

## Boundary

- Production modules under `libs/content/src` may depend only on
  `libs.content` itself and the source-independent foundations `libs.codec`,
  `libs.errors`, and `libs.math`.
- They must not import `libs.mons`, `libs.battle`, `libs.assets`,
  `libs.nds`, `libs.script`, `libs.hgss`, `libs.ui`, `game`, `app`,
  `romdump`, or `love`.
- Mon, item, and battle domains may depend on content; content never depends
  on them. The aggregate game content is composed one layer up, never here.

## Contracts

- Composition order is supplied by the caller and never inferred or sorted
  here. The last writer wins deterministically and provenance names the
  owning contributor of every surviving definition.
- Define collisions, patches of missing identities, alias cycles, missing
  alias destinations, and duplicate native identities fail loudly with
  structured errors; programming invariants use `assert`.
- Patches apply validated ordered set/remove operations; arrays replace as a
  whole. Operation shapes validate immediately, complete definitions validate
  once at freeze.
- Freezing is idempotent and transfers a detached immutable snapshot.
  Failed operations and failed freezes publish nothing. Builders reject any
  mutation after a successful freeze.
- Getters return detached copies; the native index carries only declared
  identities and custom entries never receive invented ones.
- Effectiveness data stays exact: positive-denominator rationals with zero
  for immunity. Mod type charts may stay sparse: a relation naming an
  undeclared type or a conflicting duplicate pair fails, while an omitted
  pair between declared types freezes cleanly and resolves to neutral at
  chart construction. Native producer snapshots declare every directed pair
  completely.
