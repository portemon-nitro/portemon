-- Detached validated companion draft for the save editor. The draft stages
-- explicit companion edits over a private copy of one save record and
-- validates the whole staged bucket through the durable companion owner
-- before returning anything applicable. Staging never mutates the live
-- session, the original save, or the caller's record; only a successful
-- apply returns an updated record, and a failed apply returns an
-- attributed error with nothing staged. Card possession and the
-- acquisition flag are edited coherently by named actions; there is no
-- second ownership boolean. Field ranges stay with the domain owner: the
-- draft assigns plain bucket facts and lets restoration reject them, plus
-- the editor-level savings ceiling and the card/ownership coherence rule.
-- Named preset scenarios also stage here: the draft owns each scenario's
-- precondition check and its staged operations, resolved against catalog
-- references; the scenario catalog only carries the descriptive data.
-- Pure data module: no love dependency, no runtime access.

local Errors = require("libs.errors.src.Errors")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local PlayerData = require("libs.hgss.src.save.PlayerData")
local PokegearState = require("libs.hgss.src.save.PokegearState")

---@class SaveEditorPokegearDraftOptions
---@field record table<string, unknown>
---@field refs table<string, unknown>

---@class SaveEditorPokegearDraftChange
---@field fact string
---@field detail string

---@class SaveEditorPokegearDraft
---@field private _base table<string, unknown>
---@field private _refs table<string, unknown>
---@field private _ops { op: string, args: unknown[] }[]
local SaveEditorPokegearDraft = {}
SaveEditorPokegearDraft.__index = SaveEditorPokegearDraft

local INVALID = "SAVE_EDITOR_POKEGEAR_INVALID"
local CONFLICT = "SAVE_EDITOR_POKEGEAR_CONFLICT"
local MISSING_BUCKET = "SAVE_EDITOR_POKEGEAR_UNAVAILABLE"

-- The shared preset-scenario error vocabulary. The scenario catalog raises
-- these through the same table so naming, availability, and precondition
-- failures carry one spelling on both sides of the catalog/draft edge.
SaveEditorPokegearDraft.PresetError = {
  UNKNOWN = "POKEGEAR_PRESET_UNKNOWN",
  UNAVAILABLE = "POKEGEAR_PRESET_UNAVAILABLE",
  PRECONDITION = "POKEGEAR_PRESET_PRECONDITION",
}
local PresetError = SaveEditorPokegearDraft.PresetError

local OPTIONAL_CARDS = { map = true, radio = true }

local KNOWN_OPS = {
  registerCard = true,
  clearCard = true,
  setOwnership = true,
  repairLegacyOwnership = true,
  setPreference = true,
  registerContact = true,
  setContactOrder = true,
  setContactReward = true,
  setTrigger = true,
  setCallHistory = true,
  setMarking = true,
  setMomBalance = true,
  setMomPurchases = true,
  setMomGifts = true,
  setRematch = true,
  clearRematch = true,
  setDailyIdentity = true,
}

---@param value unknown
---@return unknown
local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, item in pairs(value) do
    result[key] = copy(item)
  end
  return result
end

-- The closed staged-operation data behind named preset scenarios. Static
-- scenarios list their validated draft operations verbatim; catalog-keyed
-- scenarios resolve their keys through the helpers below. Pure data: no
-- closures. Unavailable specialties carry no operations and are never
-- stageable; they fail through the catalog's availability refusal.
local PRESET_OPS = {
  ["before-mom-gear"] = {
    { op = "setMomBalance", args = { 0 } },
    { op = "setMomGifts", args = { {} } },
    { op = "setMomPurchases", args = { {} } },
    { op = "clearCard", args = { "map" } },
    { op = "clearCard", args = { "radio" } },
  },
  ["before-elm-call"] = {
    { op = "setTrigger", args = { "test.trigger.elm", false } },
  },
  ["after-cherrygrove-map"] = {
    { op = "registerCard", args = { "map" } },
    { op = "setPreference", args = { "mapUnlockLevel", 1 } },
  },
  ["before-goldenrod-quiz"] = {
    { op = "registerCard", args = { "radio" } },
    { op = "setPreference", args = { "radioCursor", { x = 128, y = 128 } } },
  },
  ["johto-clear-radio"] = {
    { op = "registerCard", args = { "radio" } },
    { op = "setPreference", args = { "radioCursor", { x = 128, y = 128 } } },
  },
  ["rockets-active"] = {
    { op = "registerCard", args = { "radio" } },
    { op = "setTrigger", args = { "rockets.active", true } },
  },
  ["mahogany-uncleared"] = {
    { op = "registerCard", args = { "map" } },
    { op = "setPreference", args = { "mapUnlockLevel", 1 } },
  },
  ["mahogany-cleared"] = {
    { op = "registerCard", args = { "map" } },
    { op = "setPreference", args = { "mapUnlockLevel", 2 } },
  },
  ["kanto-before-power"] = {
    { op = "registerCard", args = { "map" } },
    { op = "setPreference", args = { "mapUnlockLevel", 2 } },
  },
  ["kanto-after-power"] = {
    { op = "registerCard", args = { "map" } },
    { op = "setPreference", args = { "mapUnlockLevel", 3 } },
  },
  ["kanto-expn-spotlight"] = {
    { op = "registerCard", args = { "radio" } },
    { op = "setPreference", args = { "radioCursor", { x = 200, y = 200 } } },
  },
}

---@param refs table<string, unknown>
---@return table<string, boolean> known contact keys
local function contactKeys(refs)
  local catalog = refs.catalog --[[@as table<string, unknown>]]
  assert(type(catalog) == "table" and type(catalog.contacts) == "table", "scenario presets read catalog contacts")
  local keys = {}
  for _, contact in
    ipairs(catalog.contacts --[[@as table<integer, unknown>]])
  do
    local entry = contact --[[@as table<string, unknown>]]
    if type(entry.key) == "string" and entry.key ~= "" then
      keys[entry.key] = true
    end
  end
  return keys
end

---@param refs table<string, unknown>
---@return table<string, boolean> known location keys
local function locationKeys(refs)
  local catalog = refs.catalog --[[@as table<string, unknown>]]
  assert(type(catalog) == "table" and type(catalog.locations) == "table", "scenario presets read catalog locations")
  local keys = {}
  for _, location in
    ipairs(catalog.locations --[[@as table<integer, unknown>]])
  do
    local entry = location --[[@as table<string, unknown>]]
    if type(entry.key) == "string" and entry.key ~= "" then
      keys[entry.key] = true
    end
  end
  return keys
end

---@param refs table<string, unknown>
---@param fragment string
---@return string? first contact key containing the fragment, preferring an exact caller match
local function findContact(refs, fragment)
  local keys, ordered = {}, {}
  local catalog = refs.catalog --[[@as table<string, unknown>]]
  assert(type(catalog) == "table" and type(catalog.contacts) == "table", "scenario presets read catalog contacts")
  for _, contact in
    ipairs(catalog.contacts --[[@as table<integer, unknown>]])
  do
    local entry = contact --[[@as table<string, unknown>]]
    if type(entry.key) == "string" and entry.key ~= "" and keys[entry.key] == nil then
      keys[entry.key] = true
      ordered[#ordered + 1] = entry.key
    end
  end
  for _, key in ipairs(ordered) do
    if key:lower():find(fragment, 1, true) ~= nil then
      return key
    end
  end
  return nil
end

---@param refs table<string, unknown>
---@return string? the gift contact: the Elm caller when catalogued, else the second contact
local function giftContact(refs)
  local found = findContact(refs, "elm")
  if found ~= nil then
    return found
  end
  local catalog = refs.catalog --[[@as table<string, unknown>]]
  local contacts = catalog.contacts --[[@as table<integer, unknown>]]
  if #contacts >= 2 then
    local entry = contacts[2] --[[@as table<string, unknown>]]
    if type(entry.key) == "string" then
      return entry.key
    end
  end
  return nil
end

---@param refs table<string, unknown>
---@return string? the rematch contact: an explicit rematch caller when catalogued, else the gift contact
local function rematchContact(refs)
  return findContact(refs, "rematch") or giftContact(refs)
end

---@param refs table<string, unknown>
---@return string? the marking location: a bark-town location when catalogued, else the first location
local function markLocation(refs)
  local catalog = refs.catalog --[[@as table<string, unknown>]]
  assert(type(catalog) == "table" and type(catalog.locations) == "table", "scenario presets read catalog locations")
  local locations = catalog.locations --[[@as table<integer, unknown>]]
  for _, location in ipairs(locations) do
    local entry = location --[[@as table<string, unknown>]]
    if type(entry.key) == "string" and entry.key:lower():find("bark", 1, true) ~= nil then
      return entry.key
    end
  end
  if #locations >= 1 then
    local first = locations[1] --[[@as table<string, unknown>]]
    if type(first.key) == "string" then
      return first.key
    end
  end
  return nil
end

---@param record table<string, unknown>
---@param refs table<string, unknown>
---@param key string
---@return boolean contact is registered in the staged bucket
local function isRegistered(record, refs, key)
  local ok, gear = pcall(PokegearState.restore, copy(record.pokegear), refs)
  if not ok then
    return false
  end
  local phone = gear:readPhone()
  local contacts = phone.contacts --[[@as table<string, unknown>]]
  return contacts[key] ~= nil
end

---@param refs table<string, unknown>
local function voidRefs(refs)
  assert(type(refs) == "table", "scenario presets keep their reference parameter")
end

---@param refs table<string, unknown>
---@param kind string
---@param key string?
---@return string resolved key
local function requireKey(refs, kind, key)
  voidRefs(refs)
  if type(key) ~= "string" or key == "" then
    Errors.raise(PresetError.PRECONDITION, "The selected catalog carries no " .. kind .. " for this scenario.", {})
  end
  return key --[[@as string]]
end

---@param record table<string, unknown>
---@param refs table<string, unknown>
local function checkElmReady(record, refs)
  local key = requireKey(refs, "Elm caller", giftContact(refs))
  if not isRegistered(record, refs, key) then
    Errors.raise(PresetError.PRECONDITION, "The Elm scenario needs registered contact " .. key .. ".", { key = key })
  end
end

---@param record table<string, unknown>
---@param refs table<string, unknown>
local function checkGiftReady(record, refs)
  if type(record.pokegear) ~= "table" then
    Errors.raise(PresetError.PRECONDITION, "The pending gift scenario needs a companion record.", {})
  end
  local key = giftContact(refs)
  if key == nil then
    Errors.raise(PresetError.PRECONDITION, "The selected catalog carries no gift caller for this scenario.", {})
  end
  assert(type(key) == "string", "gift scenarios name their caller")
  if contactKeys(refs)[key] ~= true then
    Errors.raise(PresetError.PRECONDITION, "The selected catalog carries no gift caller " .. key .. ".", { key = key })
  end
  if not isRegistered(record, refs, key) then
    Errors.raise(
      PresetError.PRECONDITION,
      "The pending gift scenario needs registered contact " .. key .. ".",
      { key = key }
    )
  end
end

---@param record table<string, unknown>
---@param refs table<string, unknown>
local function checkRematchReady(record, refs)
  if type(record.pokegear) ~= "table" then
    Errors.raise(PresetError.PRECONDITION, "The trainer rematch scenario needs a companion record.", {})
  end
  local key = rematchContact(refs)
  if key == nil then
    Errors.raise(PresetError.PRECONDITION, "The selected catalog carries no rematch caller for this scenario.", {})
  end
  assert(type(key) == "string", "rematch scenarios name their caller")
  if contactKeys(refs)[key] ~= true then
    Errors.raise(
      PresetError.PRECONDITION,
      "The selected catalog carries no rematch caller " .. key .. ".",
      { key = key }
    )
  end
  if not isRegistered(record, refs, key) then
    Errors.raise(
      PresetError.PRECONDITION,
      "The trainer rematch scenario needs registered contact " .. key .. ".",
      { key = key }
    )
  end
end

---@param record table<string, unknown>
---@param refs table<string, unknown>
local function checkMarkReady(record, refs)
  if type(record.pokegear) ~= "table" then
    Errors.raise(PresetError.PRECONDITION, "The marked location scenario needs a companion record.", {})
  end
  local key = markLocation(refs)
  if key == nil then
    Errors.raise(PresetError.PRECONDITION, "The selected catalog carries no marking location for this scenario.", {})
  end
  assert(type(key) == "string", "marking scenarios name their location")
  if locationKeys(refs)[key] ~= true then
    Errors.raise(
      PresetError.PRECONDITION,
      "The selected catalog carries no marking location " .. key .. ".",
      { key = key }
    )
  end
end

-- The closed scenario precondition checks behind changePreset. Scenarios
-- without an entry need only the companion record itself.
local PRESET_CHECKS = {
  ["before-elm-call"] = checkElmReady,
  ["eligible-trainer-rematch"] = checkRematchReady,
  ["pending-gift"] = checkGiftReady,
  ["marked-word-location"] = checkMarkReady,
}

---@param refs table<string, unknown>
---@return { op: string, args: unknown[] }[] gift staging for the resolved caller
local function giftOps(refs)
  local key = requireKey(refs, "gift caller", giftContact(refs))
  return {
    { op = "setContactReward", args = { key, { item = "POTION", quantity = 1 } } },
  }
end

---@param refs table<string, unknown>
---@return { op: string, args: unknown[] }[] rematch staging for the resolved caller
local function rematchOps(refs)
  local key = requireKey(refs, "rematch caller", rematchContact(refs))
  return {
    { op = "setRematch", args = { key, { stage = 1, wins = 0 } } },
  }
end

---@param refs table<string, unknown>
---@return { op: string, args: unknown[] }[] marking staging for the resolved location
local function markOps(refs)
  local key = requireKey(refs, "marking location", markLocation(refs))
  return {
    {
      op = "setMarking",
      args = { key, { icons = { 2, false, false, false }, words = { "test.word.seed", false, false, false } } },
    },
  }
end

-- Resolves one named scenario to its staged operations with catalog keys
-- bound. Static scenarios return their listed operations detached;
-- catalog-keyed scenarios resolve now so missing-asset failures surface
-- before anything stages. An unknown scenario name is a programming
-- error: callers validate names through the scenario catalog first.
---@param name string
---@param refs table<string, unknown>
---@return { op: string, args: unknown[] }[] staged operations with catalog keys resolved
function SaveEditorPokegearDraft.presetOps(name, refs)
  assert(type(name) == "string", "preset scenarios are named by behaviour")
  if type(refs) ~= "table" or type(refs.catalog) ~= "table" then
    Errors.raise(PresetError.PRECONDITION, "Companion scenarios require contact and location references.", {})
  end
  local static = PRESET_OPS[name]
  if static ~= nil then
    local staged = {}
    for _, entry in ipairs(static) do
      staged[#staged + 1] = {
        op = entry.op,
        args = copy(entry.args) --[[@as unknown[] ]],
      }
    end
    return staged
  end
  if name == "pending-gift" then
    return giftOps(refs)
  elseif name == "eligible-trainer-rematch" then
    return rematchOps(refs)
  end
  assert(name == "marked-word-location", "preset names resolve to their staged operations")
  return markOps(refs)
end

---@param saveId unknown
---@return integer deterministic seed from the save identity, never host time
local function seedFor(saveId)
  local text = type(saveId) == "string" and saveId or ""
  local hash = 0
  for index = 1, #text do
    hash = (hash * 31 + text:byte(index)) % 4294967296
  end
  return hash
end

---@param options SaveEditorPokegearDraftOptions
---@return SaveEditorPokegearDraft
function SaveEditorPokegearDraft.new(options)
  assert(type(options) == "table", "companion draft options are required")
  assert(type(options.record) == "table", "companion draft requires its source record")
  assert(type(options.refs) == "table", "companion draft requires its catalog references")
  return setmetatable({
    _base = copy(options.record),
    _refs = options.refs,
    _ops = {},
  }, SaveEditorPokegearDraft)
end

-- Records one named edit for a later atomic apply. Value checks stay with
-- apply so every staged failure surfaces as an attributed error with
-- nothing partially committed; only an unknown operation name is a
-- programming error and fails here.
---@param op string
---@param ... unknown
function SaveEditorPokegearDraft:change(op, ...)
  assert(type(op) == "string" and KNOWN_OPS[op] == true, "unknown companion draft operation: " .. tostring(op))
  self._ops[#self._ops + 1] = { op = op, args = { ... } }
end

-- Stages one named preset scenario for a later atomic apply. The scenario
-- precondition check evaluates now against the draft record while the
-- operation value checks stay with apply; a scenario without staged
-- operations (an unavailable specialty) is never stageable and fails here
-- instead of applying empty. An unknown scenario name is a programming
-- error: callers validate names through the scenario catalog first.
---@param name string
function SaveEditorPokegearDraft:changePreset(name)
  assert(type(name) == "string", "preset scenarios are named by behaviour")
  local staged, check = PRESET_OPS[name], PRESET_CHECKS[name]
  assert(staged ~= nil or check ~= nil, "unknown companion scenario: " .. tostring(name))
  if check ~= nil then
    check(self._base, self._refs)
  elseif type(self._base.pokegear) ~= "table" then
    Errors.raise(PresetError.PRECONDITION, "This scenario needs a companion record.", { name = name })
  end
  for _, entry in ipairs(SaveEditorPokegearDraft.presetOps(name, self._refs)) do
    self:change(entry.op, unpack(entry.args))
  end
end

---@param record table<string, unknown>
---@return table<string, unknown> world flags record, created when absent
local function worldFlags(record)
  assert(type(record) == "table", "draft edits read the staged record")
  if type(record.world) ~= "table" then
    record.world = { flags = {}, variables = {} }
  end
  local world = record.world --[[@as table<string, unknown>]]
  if type(world.flags) ~= "table" then
    world.flags = {}
  end
  return world.flags --[[@as table<string, unknown>]]
end

---@return number? the acquisition flag identity, or nil when uncatalogued
local function ownershipFlagId()
  local flagsByName = FieldScriptSymbols.flagsByName
  assert(type(flagsByName) == "table", "flag symbol catalog is required")
  local flagId = flagsByName.FLAG_GOT_POKEGEAR
  if type(flagId) ~= "number" or flagId % 1 ~= 0 or flagId < 0 or flagId > 0xFFFF then
    return nil
  end
  return flagId
end

---@param work table<string, unknown>
---@param refs table<string, unknown>
---@param op string
---@return table<string, unknown> the staged companion bucket, created by explicit repair only
local function ensureBucket(work, refs, op)
  if type(work.pokegear) == "table" then
    return work.pokegear --[[@as table<string, unknown>]]
  end
  if op ~= "repairLegacyOwnership" then
    Errors.raise(
      MISSING_BUCKET,
      "This save carries no companion record; run the explicit ownership repair before other companion edits.",
      { op = op }
    )
  end
  local gear = PokegearState.new({ seed = seedFor(work.saveId) }, refs)
  work.pokegear = gear:capture()
  return work.pokegear --[[@as table<string, unknown>]]
end

-- Applies one recorded operation to the staged record copy. Raises an
-- attributed error on the first invalid edit; the caller discards the
-- whole copy so no partial edit ever escapes.
---@param work table<string, unknown>
---@param refs table<string, unknown>
---@param entry { op: string, args: unknown[] }
---@param changes SaveEditorPokegearDraftChange[]
local function applyOp(work, refs, entry, changes)
  local op, args = entry.op, entry.args
  local bucket = ensureBucket(work, refs, op)
  if op == "registerCard" then
    local card = args[1]
    if type(card) ~= "string" or (card ~= "phone" and OPTIONAL_CARDS[card] ~= true) then
      Errors.raise(INVALID, "Companion card registration names map, radio, or phone.", { card = card })
    end
    bucket.registeredCards = bucket.registeredCards or { phone = true }
    local cards = bucket.registeredCards; --[[@as table<string, boolean>]]
    (cards --[[@as table<string, unknown>]])[card] = true
    local flagId = ownershipFlagId()
    assert(flagId ~= nil, "companion ownership edits require their catalogued flag")
    worldFlags(work)[flagId] = true
    changes[#changes + 1] = {
      fact = "pokegear.registeredCards",
      detail = "registers the " .. card .. " card and records companion ownership coherently",
    }
  elseif op == "clearCard" then
    local card = args[1]
    if type(card) ~= "string" or OPTIONAL_CARDS[card] ~= true then
      Errors.raise(INVALID, "Only the optional map or radio card can be cleared.", { card = card })
    end
    local cards = bucket.registeredCards --[[@as table<string, boolean>]]
    if type(cards) == "table" then
      (cards --[[@as table<string, unknown>]])[card] = nil
    end
    changes[#changes + 1] = { fact = "pokegear.registeredCards", detail = "clears the " .. card .. " card" }
  elseif op == "setOwnership" then
    if type(args[1]) ~= "boolean" then
      Errors.raise(INVALID, "Companion ownership takes a boolean value.", {})
    end
    local flagId = ownershipFlagId()
    assert(flagId ~= nil, "companion ownership edits require their catalogued flag")
    local flags = worldFlags(work)
    if args[1] then
      flags[flagId] = true
    else
      flags[flagId] = nil
    end
    changes[#changes + 1] =
      { fact = "world.flags.FLAG_GOT_POKEGEAR", detail = args[1] and "records ownership" or "clears ownership" }
  elseif op == "repairLegacyOwnership" then
    local flagId = ownershipFlagId()
    assert(flagId ~= nil, "companion ownership edits require their catalogued flag")
    worldFlags(work)[flagId] = true
    local cards = bucket.registeredCards --[[@as table<string, boolean>]]
    if type(cards) ~= "table" or cards.phone ~= true then
      local repaired = bucket.registeredCards --[[@as table<string, unknown>]]
      if type(repaired) ~= "table" then
        repaired = {}
        bucket.registeredCards = repaired
      end
      repaired.phone = true
    end
    changes[#changes + 1] = {
      fact = "world.flags.FLAG_GOT_POKEGEAR",
      detail = "explicit legacy repair: marks ownership without reconstructing acquisition history",
    }
  elseif op == "setPreference" then
    local name, value = args[1], args[2]
    if type(name) ~= "string" then
      Errors.raise(INVALID, "Companion preference edits name a known preference.", { preference = name })
    end
    bucket[name] = copy(value)
    changes[#changes + 1] = { fact = "pokegear." .. name, detail = "assigns the " .. name .. " preference" }
  elseif op == "registerContact" then
    local phone = bucket.phone --[[@as table<string, unknown>]]
    assert(type(phone) == "table" and type(phone.contacts) == "table", "contact edits read phone state")
    local key = args[1]
    if type(key) ~= "string" or key == "" then
      Errors.raise(INVALID, "Contact registration carries a semantic contact key.", { key = key })
    end
    local contacts = phone.contacts --[[@as table<string, unknown>]]
    if contacts[key] == nil then
      contacts[key] = {}
      local order = bucket.contactOrder --[[@as table<integer, string>]]
      assert(type(order) == "table", "contact edits read the contact order")
      order[#order + 1] = key
    end
    changes[#changes + 1] = { fact = "pokegear.phone.contacts", detail = "registers contact " .. key }
  elseif op == "setContactOrder" then
    bucket.contactOrder = copy(args[1])
    changes[#changes + 1] = { fact = "pokegear.contactOrder", detail = "reorders registered contacts" }
  elseif op == "setContactReward" then
    local key = args[1]
    if type(key) ~= "string" or key == "" then
      Errors.raise(INVALID, "Contact rewards carry a semantic contact key.", { key = key })
    end
    local phone = bucket.phone --[[@as table<string, unknown>]]
    assert(type(phone) == "table" and type(phone.contacts) == "table", "reward edits read phone state")
    local contacts = phone.contacts --[[@as table<string, unknown>]]
    if contacts[key] == nil then
      contacts[key] = {}
    end
    local contactEntry = contacts[key] --[[@as table<string, unknown>]]
    assert(type(contactEntry) == "table", "reward edits read the contact entry")
    contactEntry.reward = copy(args[2])
    changes[#changes + 1] = { fact = "pokegear.phone.contacts", detail = "stages the pending reward for " .. key }
  elseif op == "setTrigger" then
    local phone = bucket.phone --[[@as table<string, unknown>]]
    assert(type(phone) == "table" and type(phone.triggers) == "table", "trigger edits read phone state")
    local triggers = phone.triggers --[[@as table<string, boolean>]]
    if args[2] then
      (triggers --[[@as table<string, unknown>]])[args[1]] = true
    else
      (triggers --[[@as table<string, unknown>]])[args[1]] = nil
    end
    changes[#changes + 1] = { fact = "pokegear.phone.triggers", detail = "switches a call trigger" }
  elseif op == "setCallHistory" then
    local phone = bucket.phone --[[@as table<string, unknown>]]
    assert(type(phone) == "table", "history edits read phone state")
    phone.history = copy(args[1])
    changes[#changes + 1] = { fact = "pokegear.phone.history", detail = "replaces the call journal" }
  elseif op == "setMarking" then
    local key = args[1]
    if type(key) ~= "string" or key == "" then
      Errors.raise(INVALID, "Map markings carry a semantic location key.", { key = key })
    end
    if type(bucket.markings) ~= "table" then
      bucket.markings = {}
    end
    local markings = bucket.markings --[[@as table<string, unknown>]]
    if args[2] == nil then
      markings[key] = nil
    else
      markings[key] = copy(args[2])
    end
    changes[#changes + 1] = { fact = "pokegear.markings", detail = "edits the marking for " .. key }
  elseif op == "setMomBalance" then
    local value = args[1]
    if type(value) ~= "number" or value % 1 ~= 0 or value < 0 or value > PlayerData.MAX_MONEY then
      Errors.raise(INVALID, "Savings balance must be a whole amount within the companion savings ceiling.", {
        value = value,
      })
    end
    local phone = bucket.phone --[[@as table<string, unknown>]]
    assert(type(phone) == "table" and type(phone.mom) == "table", "savings edits read savings state")
    local mom = phone.mom --[[@as table<string, unknown>]]
    mom.balance = value
    changes[#changes + 1] = { fact = "pokegear.phone.mom", detail = "assigns the savings balance" }
  elseif op == "setMomPurchases" then
    local phone = bucket.phone --[[@as table<string, unknown>]]
    assert(type(phone) == "table" and type(phone.mom) == "table", "savings edits read savings state")
    local momPurchases = phone.mom --[[@as table<string, unknown>]]
    momPurchases.purchases = copy(args[1])
    changes[#changes + 1] = { fact = "pokegear.phone.mom", detail = "assigns the claimed purchase flags" }
  elseif op == "setMomGifts" then
    local phone = bucket.phone --[[@as table<string, unknown>]]
    assert(type(phone) == "table" and type(phone.mom) == "table", "savings edits read savings state")
    local momGifts = phone.mom --[[@as table<string, unknown>]]
    momGifts.gifts = copy(args[1])
    changes[#changes + 1] = { fact = "pokegear.phone.mom", detail = "assigns the pending gift queue" }
  elseif op == "setRematch" then
    local key = args[1]
    if type(key) ~= "string" or key == "" then
      Errors.raise(INVALID, "Rematch records carry a semantic challenger key.", { key = key })
    end
    local phone = bucket.phone --[[@as table<string, unknown>]]
    assert(type(phone) == "table" and type(phone.rematches) == "table", "rematch edits read rematch state")
    local rematches = phone.rematches --[[@as table<string, unknown>]]
    rematches[key] = copy(args[2])
    changes[#changes + 1] = { fact = "pokegear.phone.rematches", detail = "stages the rematch record for " .. key }
  elseif op == "clearRematch" then
    local phone = bucket.phone --[[@as table<string, unknown>]]
    assert(type(phone) == "table" and type(phone.rematches) == "table", "rematch edits read rematch state")
    local rematchesClear = phone.rematches --[[@as table<string, unknown>]]
    rematchesClear[args[1]] = nil
    changes[#changes + 1] = { fact = "pokegear.phone.rematches", detail = "clears a rematch record" }
  else
    assert(op == "setDailyIdentity", "draft operations cover the closed operation set")
    local identity = args[1]
    if type(identity) ~= "table" then
      Errors.raise(INVALID, "Daily identity edits carry both shared daily seeds.", {})
    end
    local seeds = identity --[[@as table<string, unknown>]]
    local calendar = bucket.calendar --[[@as table<string, unknown>]]
    assert(type(calendar) == "table", "daily edits read the calendar record")
    calendar.dailyGroupSeed = seeds.dailyGroupSeed
    calendar.outbreakSeed = seeds.outbreakSeed
    changes[#changes + 1] = { fact = "pokegear.calendar", detail = "assigns the shared daily seeds" }
  end
end

---@param work table<string, unknown>
local function checkOwnershipCoherence(work)
  local bucket = work.pokegear --[[@as table<string, unknown>]]
  assert(type(bucket) == "table", "coherence checks read the staged bucket")
  local cards = bucket.registeredCards --[[@as table<string, boolean>]]
  local optional = type(cards) == "table" and (cards.map == true or cards.radio == true) or false
  if not optional then
    return
  end
  local flagId = ownershipFlagId()
  assert(flagId ~= nil, "companion ownership edits require their catalogued flag")
  local world = work.world --[[@as table<string, unknown>]]
  local owned = type(world) == "table"
    and type(world.flags) == "table"
    and (world.flags --[[@as table<integer, boolean>]])[flagId] == true
  if not owned then
    Errors.raise(
      CONFLICT,
      "Optional companion cards require recorded companion ownership; repair ownership or clear the card.",
      {}
    )
  end
end

---@param record table<string, unknown>
---@param refs table<string, unknown>
---@param ops { op: string, args: unknown[] }[]
---@return table<string, unknown>? updated
---@return Errors.Error? error
---@return SaveEditorPokegearDraftChange[]? changes
local function runOps(record, refs, ops)
  local work = copy(record)
  local changes = {}
  local ok, failure = pcall(function()
    for _, entry in ipairs(ops) do
      applyOp(work, refs, entry, changes)
    end
    if type(work.pokegear) == "table" then
      -- Validate a throwaway copy so restoration can never silently repair
      -- the record an unchanged or changed draft returns.
      PokegearState.restore(copy(work.pokegear), refs)
      checkOwnershipCoherence(work)
    end
  end)
  if not ok then
    if Errors.is(failure) then
      return nil,
        failure, --[[@as Errors.Error]]
        nil
    end
    error(failure, 0)
  end
  return work, nil, changes
end

---@return boolean valid
function SaveEditorPokegearDraft:validate()
  local _, failure = runOps(self._base, self._refs, self._ops)
  return failure == nil
end

---@return table<string, unknown>? updated
---@return Errors.Error? error
function SaveEditorPokegearDraft:apply()
  local updated, failure = self:applyTo(copy(self._base))
  if updated == nil then
    return nil, assert(failure)
  end
  return updated, nil
end

-- Applies the recorded edits onto an explicit record copy, usually the
-- owning session's current candidate. The input record is never mutated;
-- a failed apply returns nothing applicable.
---@param record table<string, unknown>
---@return table<string, unknown>? updated
---@return Errors.Error? error
function SaveEditorPokegearDraft:applyTo(record)
  assert(type(record) == "table", "draft application requires its target record")
  local updated, failure = runOps(record, self._refs, self._ops)
  if updated == nil then
    return nil, assert(failure)
  end
  return updated, nil
end

-- The ordered human-readable change summary for pre-save review, including
-- explicit legacy repairs. Computed without mutating the draft.
---@return SaveEditorPokegearDraftChange[]
function SaveEditorPokegearDraft:changes()
  local _, applyError, changes = runOps(self._base, self._refs, self._ops)
  if changes == nil then
    error(assert(applyError), 0)
  end
  return changes
end

return SaveEditorPokegearDraft
