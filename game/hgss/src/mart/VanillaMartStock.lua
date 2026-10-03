-- HGSS default stock selection policy. Resolved records are owned snapshots
-- for the transaction service and contain semantic keys only.

local VanillaMartStock = {}

local function requireSelector(value, maximum, what)
  assert(
    type(value) == "number" and value % 1 == 0 and value >= 0 and value <= maximum,
    "invalid mart " .. what .. " selector"
  )
end

local function itemPrice(items, key)
  return items:item(key).price
end

local function itemEntry(items, key, unitPrice, position, restriction)
  local entry = {
    key = "item:" .. position .. ":" .. key,
    displayItemKey = key,
    description = { kind = "item" },
    unitPrice = unitPrice == nil and itemPrice(items, key) or unitPrice,
    destination = { kind = "bag", key = key },
    restriction = restriction or { kind = "none" },
  }
  return entry
end

local function base(key, currency, presentationKind, quantityMode, bonusPolicy, entries)
  return {
    key = key,
    currency = currency,
    presentationKind = presentationKind,
    quantityMode = quantityMode,
    bonusPolicy = bonusPolicy,
    entries = entries,
  }
end

local function assertCatalog(catalog)
  assert(
    type(catalog) == "table" and type(catalog.mart) == "table" and catalog.items ~= nil,
    "mart stock resolver requires { mart, items }"
  )
end

local function resolveStandard(context, catalog)
  local badges = context.badges
  assert(
    type(badges) == "number" and badges % 1 == 0 and badges >= 0 and badges <= 65535,
    "mart resolver requires a 16-bit badge snapshot"
  )
  local count = 0
  for index = 0, 15 do
    if math.floor(badges / (2 ^ index)) % 2 == 1 then
      count = count + 1
    end
  end
  local tier = count == 0 and 1 or count <= 2 and 2 or count <= 4 and 3 or count <= 6 and 4 or count == 7 and 5 or 6
  local entries = {}
  for _, row in ipairs(catalog.mart.normalTiers) do
    if row.minimumTier <= tier then
      local filtered = row.itemKey == "POKE_BALL"
        and type(context.readFlag) == "function"
        and context.readFlag(0x09A) == false
      if not filtered then
        entries[#entries + 1] = itemEntry(catalog.items, row.itemKey, nil, #entries)
      end
    end
  end
  return base("standard", "money", "items", "multiple", "premier_ball", entries)
end

local function resolveSpecial(descriptor, context, catalog)
  requireSelector(descriptor.selector, 29, "special")
  local entries = {}
  for _, row in ipairs(catalog.mart.specialStocks[descriptor.selector + 1]) do
    local filtered = row.subjectKey == "POKE_BALL"
      and type(context.readFlag) == "function"
      and context.readFlag(0x09A) == false
    if not filtered then
      entries[#entries + 1] = itemEntry(catalog.items, row.subjectKey, nil, #entries)
    end
  end
  return base("special:" .. descriptor.selector, "money", "items", "multiple", "premier_ball", entries)
end

local function resolveSeals(descriptor, catalog)
  requireSelector(descriptor.selector, 6, "seal")
  local entries = {}
  for index, row in ipairs(catalog.mart.sealStocks[descriptor.selector + 1]) do
    local seal = assert(catalog.mart.seals[row.subjectKey], "mart seal metadata is required")
    entries[index] = {
      key = "seal:" .. index .. ":" .. row.subjectKey,
      displayItemKey = seal.displayItemKey,
      description = { kind = "literal", value = seal.description },
      unitPrice = 100,
      destination = { kind = "seal", key = row.subjectKey },
      restriction = { kind = "none" },
    }
  end
  return base("seal:" .. descriptor.selector, "money", "seals", "multiple", "none", entries)
end

local function resolveDecorations(descriptor, catalog)
  requireSelector(descriptor.selector, 1, "decoration")
  local entries = {}
  for index, row in ipairs(catalog.mart.decorationStocks[descriptor.selector + 1]) do
    local decoration = assert(catalog.mart.decorations[row.subjectKey], "mart decoration metadata is required")
    entries[index] = {
      key = "decoration:" .. index .. ":" .. row.subjectKey,
      displayItemKey = decoration.displayItemKey,
      description = { kind = "literal", value = decoration.description },
      unitPrice = 100,
      destination = { kind = "unavailable", key = row.subjectKey },
      restriction = { kind = "none" },
    }
  end
  return base("decoration:" .. descriptor.selector, "money", "legacy_decorations", "single", "none", entries)
end

local function resolveAthlete(context, catalog)
  assert(
    type(context.weekday) == "number" and context.weekday % 1 == 0 and context.weekday >= 0 and context.weekday <= 6,
    "mart resolver requires a Sunday-based weekday"
  )
  assert(type(context.nationalDex) == "boolean", "mart resolver requires nationalDex")
  local stockIndex = context.weekday + (context.nationalDex and 7 or 0)
  local entries = {}
  for index, row in ipairs(catalog.mart.athleteStocks[stockIndex + 1]) do
    local destination = catalog.mart.apricorns[row.subjectKey] ~= nil and { kind = "apricorn", key = row.subjectKey }
      or { kind = "bag", key = row.subjectKey }
    entries[index] = {
      key = "athlete:" .. stockIndex .. ":" .. index,
      displayItemKey = row.subjectKey,
      description = { kind = "item" },
      unitPrice = row.price.value,
      destination = destination,
      restriction = { kind = "daily_slot", slot = index - 1 },
    }
  end
  return base("athlete:" .. stockIndex, "athlete_points", "athlete_items", "single", "none", entries)
end

local function resolveCards(context, catalog)
  assert(
    type(context.cardPrefix) == "number"
      and context.cardPrefix % 1 == 0
      and context.cardPrefix >= 0
      and context.cardPrefix <= 27,
    "mart resolver requires a Data Card prefix"
  )
  local group = math.min(math.floor(context.cardPrefix / 6), 4)
  local entries = {}
  for index, row in ipairs(catalog.mart.dataCardStocks[group + 1]) do
    assert(catalog.mart.cards[row.subjectKey], "Data Card ownership metadata is required")
    entries[index] = {
      key = "card:" .. group .. ":" .. row.subjectKey,
      displayItemKey = row.subjectKey,
      description = { kind = "item" },
      unitPrice = row.price.value,
      destination = { kind = "card", key = row.subjectKey },
      restriction = { kind = "owned_card", key = row.subjectKey },
      capacityProbe = { kind = "bag", key = row.subjectKey },
    }
  end
  return base("data_cards:" .. group, "athlete_points", "athlete_cards", "single", "none", entries)
end

function VanillaMartStock.resolve(descriptor, context, catalog)
  assert(type(descriptor) == "table" and type(descriptor.kind) == "string", "mart launch descriptor is required")
  assert(type(context) == "table", "mart resolver context is required")
  assertCatalog(catalog)
  if descriptor.kind == "standard" then
    return resolveStandard(context, catalog)
  end
  if descriptor.kind == "special" then
    return resolveSpecial(descriptor, context, catalog)
  end
  if descriptor.kind == "seal" then
    return resolveSeals(descriptor, catalog)
  end
  if descriptor.kind == "decoration" then
    return resolveDecorations(descriptor, catalog)
  end
  if descriptor.kind == "athlete" then
    return resolveAthlete(context, catalog)
  end
  if descriptor.kind == "data_cards" then
    return resolveCards(context, catalog)
  end
  if descriptor.kind == "sell" then
    return base("sell", "money", "items", "multiple", "none", {})
  end
  error("unsupported mart launch descriptor: " .. descriptor.kind, 0)
end

return VanillaMartStock
