# Battle extension guide

This guide describes how to extend battles through the public authoring
surface without forking the simulation kernel. Everything here runs
through the same session, controllers, and semantic events as native
battles: extensions register typed payloads with explicit budgets and
join policies, and the kernel keeps its state invariants for every
format.

## Composing content

Compose ordered contributions through the battle facade:

```lua
local Battle = require("gen4.battle")
local resolved, bound, content = Battle.compose({
  { owner = "glimmer-pack", revision = "1", install = function(builder, behaviors)
    builder:define("types", "glimmer", {
      key = "glimmer",
      name = "Glimmer",
      relations = {
        { attack = "glimmer", defend = "glimmer", numerator = 1, denominator = 1 },
        { attack = "glimmer", defend = "normal", numerator = 2, denominator = 1 },
      },
    }, "glimmer-pack")
    behaviors:registerRuleset("glimmer:rules", { key = "glimmer:rules", chart = "glimmer:rules" }, "glimmer-pack")
  end },
})
```

Declaration order decides patch resolution: a contributor may name
`after` and `before` owners to constrain its position, and input order
breaks remaining ties deterministically. Numeric `priority` fields never
influence resolution, so load order can never become mechanics timing.
Dependency cycles fail the whole composition instead of resolving in an
arbitrary order. A compatibility contribution names
`suppresses = { { kind = "moves", key = "canon:bolt" } }` to remove
exactly the named canonical contributions; everything it does not name
keeps resolving to its canonical owner.

Depend on a concrete provider, never on a substitutable capability.
When a patch must apply after one specific provider, name that provider:

```lua
{ owner = "glimmer-compat", revision = "2", after = { "glimmer-pack" }, install = function(builder)
  builder:patch("tuning", "power", { { op = "set", path = { "value" }, value = "gleam" } }, "glimmer-compat")
end },
```

Ordering between providers is the wrapper order for overlapping
patches; effect activation order inside battle stays source-defined and
is never reordered by contribution order.

## Formats

Native battles run under concrete format policies owned by the native
format module: singles, doubles, two-trainer allied battles, partner
battles, and the battle-level parts of facility and link battles. Each
policy owns its topology validation, its admitted action vocabulary, its
explicit per-actor action budgets, its target scoping, and its
restoration, reward, and legality consequences. Native party limits live
in these policies, not in a global bound, and allied participants may
share a side without ever sharing a roster or an inventory handle.

Custom formats register through the same facade:

```lua
Battle.registerFormat("glimmer:skirmish", { key = "glimmer:skirmish", chart = "glimmer:skirmish" })
Battle.registerAction("glimmer:cheer", { module = "glimmer.cheer", version = 1 })
local scenario = Battle.createScenario({ ruleset = "glimmer:rules", format = "glimmer:skirmish", seed = 7 })
local session = Battle.newSession(scenario, content)
```

`createScenario` builds a validated one-active-per-side scaffold the
caller may override field by field; binding the ruleset and format to
frozen content stays with session construction, which fails on unknown
rulesets instead of guessing mechanics. A format admits its action
vocabulary per actor with an explicit count; asymmetric proof formats
grant the boss extra actions through that budget rather than by
duplicating the boss combatant or letting every actor submit arbitrary
actions.

Targets are either position-bound or activation-bound. A position target
follows whoever currently holds the slot, while a combatant target pins
the entry token it was issued for; a stale intent locked to a replaced
entry resolves to nothing instead of retargeting by accident.

## Mid-battle joins

All membership changes stage through validated topology preparation
and publish through the session owner at a declared settlement
boundary:

```lua
local Topology = require("libs.battle.src.Topology")
local staged = Topology.prepareJoin(session, {
  reason = "sos-call",
  participant = { id = 2, side = 2, controller = "beta", roster = { { id = 5 } }, context = {} },
  combatants = { { id = 5, mon = reinforcement } },
  positions = { { id = 3, side = 2, eligibleParticipants = { 2 }, occupant = 5 } },
  settlementBoundary = "round-end",
})
local receipt = Topology.applyJoin(session, staged)
```

Preparation validates roster, participant, position, and inventory
ownership without touching live state; combatant and position identities
are never reused and entry tokens grow monotonically. Applying a join
issues a new batch epoch, so an outstanding decision batch never stays
silently valid across the topology change. Joined combatants enter with
their entry effects and wait for the next batch: the newcomer gets no
action in the batch that was open when the join published. The same
path assembles large lineups at scenario construction time.

## Custom content without native identities

Custom types, species, moves, abilities, and effect state resolve
semantically and carry no native identity. Effectiveness charts are
scoped per ruleset, so altered relations apply inside one session while
other running sessions keep their own charts. Session capture, restore,
and capture flows treat custom records like any other state, while
native-index lookups refuse content that declares no native identity
with a clear unknown-identity error instead of a silent neutral
fallback.

## Custom item pockets

A mod may add a named Bag pocket and items that live in it without
touching the eight native pockets:

```lua
local ItemCatalog = require("libs.items.src.ItemCatalog")
local root = ItemFixture.buildAssetRoot()
root.pockets["alchemy"] = { capacity = 8, maxQuantity = 99, ordering = "manual" }
root.pocketNames["alchemy"] = "Alchemy"
root.items["alchemy:ELIXIR"] = {
  name = "Alchemist Elixir",
  nameIndefinite = "an Alchemist Elixir",
  namePlural = "Alchemist Elixirs",
  description = "A draught of bottled focus.",
  pocket = "alchemy",
  preventToss = false,
  selectable = false,
  isBall = false,
  friendshipBoost = false,
  icon = "alchemy:ELIXIR",
  isHm = false,
  canHold = true,
  heldFormEffect = "none",
  partyUse = { kind = "none" },
}
local catalog = ItemCatalog.fromResolved(root)
local bag = HgssBagService.new({ catalog = catalog })
assert(bag:add("alchemy:ELIXIR", 2))
local slots = bag:pocketItems("alchemy")
```

Custom slots persist under the save's optional `customPockets` member
while vanilla saves emit nothing extra. The retail Bag widget keeps its
eight native tabs: nothing appears there automatically, so mods read
custom slots through `pocketItems` or ship their own UI. Loading a
modded save without the declaring catalog fails the restore instead of
dropping items, leaving the last valid save in place.

## Future broker integration

The engine broker remains the only invasive patch mechanism.
Contributions address canonical targets through `(owner, key)` identity
today, and every registration method keeps that module boundary so the
broker can wrap it later; this surface ships no competing numeric
patch priority and no duplicate dependency broker.

## Limitations

A captured monster that cannot join a full party is reported as not
retained, with an explicit reason, rather than stored anywhere: there
is no hidden overflow storage. Overworld presentation reuses the same
session, controllers, and semantic events while the field stays the
visual context; no screen coordinates enter damage logic, and
real-time overworld combat would be a different ruleset, not an
extension of these policies.
