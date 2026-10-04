# Mart scripts

HGSS scripts can open the existing mart flows with the API 1 `mart` operation,
read the two retail shop queries with `martQuery`, or provide a serializable
stock record for a custom shop. These operations use the ordinary script
compiler and the same field-owned mart service as retail shops.

## Opening a shop

Each launch takes one specification table. The selector is read once when the
script reaches the operation. Only `special`, `seal`, and `decoration` use a
selector. Standard stock selects its tier through the default provider; the
halfword consumed by retail `MartBuy` is unused by the source handler.

```lua
local S = require("gen4.script")

local stock = {
  key = "sample_potion_stock",
  currency = "money",
  presentationKind = "items",
  quantityMode = "multiple",
  bonusPolicy = "none",
  entries = {
    {
      key = "potion",
      displayItemKey = "ITEM_POTION",
      description = { kind = "item" },
      unitPrice = 100,
      destination = { kind = "bag", key = "ITEM_POTION" },
      restriction = { kind = "none" },
    },
  },
}

local script = S.script({
  api = 1,
  id = "addon.supply_clerk",
  steps = {
    S.mart({ kind = "custom", stock = stock }),
    S.martQuery({ kind = "card_prefix", result = S.var("VAR_SPECIAL_CARD_PREFIX") }),
  },
})
```

Other launch records are `S.mart({ kind = "standard" })`,
`S.mart({ kind = "special", selector = S.var("VAR_SPECIAL_STOCK") })`,
`S.mart({ kind = "seal", selector = 0 })`,
`S.mart({ kind = "decoration", selector = 0 })`,
`S.mart({ kind = "athlete" })`, `S.mart({ kind = "data_cards" })`, and
`S.mart({ kind = "sell" })`. A shop launch blocks the calling foreground
script until the child closes and field restoration finishes.

Custom stock is an ordered array of semantic entries. Use the same schema as
the example. Accepted presentation/currency/quantity combinations are:

- `items`: money, multiple quantities, Bag destinations;
- `seals`: money, multiple quantities, Seal Case destinations;
- `athlete_items`: Athlete Points, one item per selection, Bag or Apricorn destinations;
- `athlete_cards`: Athlete Points, one card per selection, Data Card destinations;
- `legacy_decorations`: money, one item per selection, unavailable destinations.

Prices are integers from 0 through 999999; zero-price stock is supported. Item
keys and destination keys must exist in the active catalogs. Data Cards require
matching ownership restrictions and a Bag capacity probe. Daily-slot
restrictions use a slot from 0 through 11. The transaction service validates
the full record before showing the shop. Invalid stock raises a script task
fault without publishing a partial shop. An uncommitted transaction grants
nothing; a completed transaction remains committed if a later presentation
step fails.

## Replacing default stock selection

The game composition accepts an optional `martStockResolver` function through
the field runtime options. Its signature is:

```lua
martStockResolver(descriptor, openingContext, catalog) -> resolvedStock
```

The descriptor is the evaluated launch record. `openingContext` is a
read-only snapshot for that opening; the default provider uses badge state and
the tutorial Poké Ball flag for standard stock, the selector for special,
Seal, and Decoration stock, Sunday-based weekday and National Dex state for
Athlete stock, and the first unowned Data Card index for card stock. The
resolver's result is copied and validated before the transaction starts.
Opening stock does not change while its shop is open. Custom inline stock is
already explicit and bypasses the resolver, so the default badge tiers never
filter it. Use script conditions and a selected launch descriptor when stock
needs to depend on another world value.

## Queries and persistent state

`S.martQuery({ kind = "athlete_available", result = S.var("VAR_RESULT") })`
writes integer 1 when an Athlete shop entry remains available that day and 0
otherwise. `card_prefix` writes the first unowned Data Card index from 0
through 27; 27 means all cards are owned. Results are written in the same
script tick. Queries made during an open shop use its retained date and stock
context; they do not reset daily purchases partway through the shop.

Money changes the existing player profile. Athlete Points, daily purchases,
Data Card ownership, Apricorn quantities, and Seal Case contents use the
mart save bucket and survive normal save/load. Historical player, Bag, and
mart data remain part of save migration and validation.

Legacy Decoration and Seal shops preserve their retail differences. Seal
stock grants items into the Seal Case. Decoration entries retain their
source-facing display and price, but their unavailable destination does not
grant an invented Decoration item. Competition explanations/statistics and
competition gameplay remain unsupported.

The source `ScrCmd_815 0` prelude is supported as a no-op because the mart host
returns to the default field display on close. Other `ScrCmd_815` values remain
unsupported; the operand is an immediate, not a variable reference.
