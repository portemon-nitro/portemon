-- Focused companion projection for the save editor: card possession and
-- preferences, contact order with pending rewards, markings, savings, and
-- rematch state rendered with semantic catalog names, plus the labeled
-- semantic actions the editor dispatches through its existing activation
-- handlers. The projection is pure observation over a detached record: a
-- pending validation failure is reported on the card without committing
-- anything, and malformed buckets surface as attributed failures instead
-- of silent discards. Pure data module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local PokegearState = require("libs.hgss.src.save.PokegearState")
local GridCard = require("app.src.saveeditor.SaveEditorCard")

---@class SaveEditorPokegearCardRow
---@field label string
---@field value string

---@class SaveEditorPokegearCardAction
---@field id string
---@field label string
---@field kind string
---@field semantic string
---@field preset string?

---@class SaveEditorPokegearCardSpec
---@field title string
---@field available boolean
---@field reason string?
---@field rows SaveEditorPokegearCardRow[]
---@field actions SaveEditorPokegearCardAction[]
---@field pendingError string?
local SaveEditorPokegearCard = {}

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

---@param refs table<string, unknown>?
---@return table<string, string> contact key to display name
local function contactNames(refs)
  local names = {}
  if type(refs) ~= "table" or type(refs.catalog) ~= "table" then
    return names
  end
  local catalog = refs.catalog --[[@as table<string, unknown>]]
  if type(catalog.contacts) ~= "table" then
    return names
  end
  for _, contact in
    ipairs(catalog.contacts --[[@as table<integer, unknown>]])
  do
    local entry = contact --[[@as table<string, unknown>]]
    if type(entry.key) == "string" and entry.key ~= "" then
      if type(entry.name) == "string" and entry.name ~= "" then
        names[entry.key] = entry.name
      else
        names[entry.key] = entry.key
      end
    end
  end
  return names
end

---@param record table<string, unknown>
---@return boolean companion ownership is recorded beside the card bits
local function hasOwnership(record)
  local flagsByName = FieldScriptSymbols.flagsByName
  assert(type(flagsByName) == "table", "flag symbol catalog is required")
  local flagId = flagsByName.FLAG_GOT_POKEGEAR
  if type(flagId) ~= "number" then
    return false
  end
  local world = record.world --[[@as table<string, unknown>]]
  return type(world) == "table"
    and type(world.flags) == "table"
    and (world.flags --[[@as table<integer, boolean>]])[flagId] == true
end

---@param cards table<string, boolean>
---@return string
local function cardSummary(cards)
  local owned = {}
  for _, card in ipairs({ "phone", "map", "radio" }) do
    if cards[card] == true then
      owned[#owned + 1] = card
    end
  end
  if #owned == 0 then
    return "no cards"
  end
  return table.concat(owned, ", ")
end

---@param bucket table<string, unknown>
---@param names table<string, string>
---@return SaveEditorPokegearCardRow[]
local function buildRows(bucket, names)
  local rows = {}
  local cards = bucket.registeredCards --[[@as table<string, boolean>]]
  rows[#rows + 1] = {
    label = "Cards",
    value = type(cards) == "table" and cardSummary(cards) or "unreadable",
  }
  rows[#rows + 1] = {
    label = "Skin",
    value = "skin " .. tostring(bucket.skin) .. ", opens on " .. tostring(bucket.lastApp),
  }
  rows[#rows + 1] = { label = "Map tier", value = "tier " .. tostring(bucket.mapUnlockLevel) }
  local phone = bucket.phone --[[@as table<string, unknown>]]
  assert(type(phone) == "table", "card rows read phone state")
  local order = bucket.contactOrder --[[@as table<integer, string>]]
  assert(type(order) == "table", "card rows read the contact order")
  local contacts = phone.contacts --[[@as table<string, unknown>]]
  assert(type(contacts) == "table", "card rows read phone contacts")
  local contactBits = {}
  for _, key in ipairs(order) do
    local entry = contacts[key] --[[@as table<string, unknown>]]
    local pending = type(entry) == "table" and entry.reward ~= nil and " (gift waits)" or ""
    contactBits[#contactBits + 1] = (names[key] or key) .. pending
  end
  rows[#rows + 1] = {
    label = "Contacts",
    value = #contactBits > 0 and table.concat(contactBits, "; ") or "none registered",
  }
  local mom = phone.mom --[[@as table<string, unknown>]]
  assert(type(mom) == "table", "card rows read savings state")
  local gifts = mom.gifts --[[@as table<integer, unknown>]]
  rows[#rows + 1] = {
    label = "Savings",
    value = tostring(mom.balance) .. " held, " .. tostring(type(gifts) == "table" and #gifts or 0) .. " gifts queued",
  }
  local rematches = phone.rematches --[[@as table<string, unknown>]]
  local rematchCount = 0
  if type(rematches) == "table" then
    for _ in pairs(rematches) do
      rematchCount = rematchCount + 1
    end
  end
  rows[#rows + 1] = { label = "Rematches", value = tostring(rematchCount) .. " staged" }
  local markings = bucket.markings --[[@as table<string, unknown>]]
  local markingCount = 0
  if type(markings) == "table" then
    for _ in pairs(markings) do
      markingCount = markingCount + 1
    end
  end
  rows[#rows + 1] = { label = "Markings", value = tostring(markingCount) .. " locations marked" }
  return rows
end

---@return SaveEditorPokegearCardAction[]
local function buildActions()
  return {
    {
      id = "companion:repair-ownership",
      label = "Repair ownership",
      kind = "companion.repair-ownership",
      semantic = "secondary",
    },
    {
      id = "companion:choose-preset",
      label = "Apply scenario",
      kind = "companion.choose-preset",
      semantic = "secondary",
    },
  }
end

-- Describes the companion card for one detached record. Never mutates its
-- inputs; validation failures are reported as the pending error beside
-- the last readable rows instead of committing partial edits.
---@param record table<string, unknown>
---@param refs table<string, unknown>?
---@return SaveEditorPokegearCardSpec
function SaveEditorPokegearCard.describe(record, refs)
  assert(type(record) == "table", "companion card describes a save record")
  if type(record.pokegear) ~= "table" then
    return {
      title = "Companion",
      available = false,
      reason = "This save carries no companion record yet.",
      rows = {},
      actions = buildActions(),
    }
  end
  if refs == nil then
    return {
      title = "Companion",
      available = false,
      reason = "The companion catalog is not provisioned for this version.",
      rows = {},
      actions = buildActions(),
    }
  end
  local ok, gearOrError = pcall(PokegearState.restore, copy(record.pokegear), refs)
  if not ok then
    local reason = Errors.is(gearOrError) and Errors.format(gearOrError) or tostring(gearOrError)
    return {
      title = "Companion",
      available = true,
      rows = {},
      actions = buildActions(),
      pendingError = reason,
    }
  end
  local gear = gearOrError
  local bucket = gear:capture()
  local rows = buildRows(bucket, contactNames(refs))
  if not hasOwnership(record) then
    rows[#rows + 1] = { label = "Ownership", value = "not recorded; repair before granting cards" }
  end
  return {
    title = "Companion",
    available = true,
    rows = rows,
    actions = buildActions(),
  }
end

-- Resolves card cells through the shared six-cell grid mechanism so the
-- companion card keeps the editor's icon-left/text-right geometry.
---@param bounds { x: number, y: number, width: number, height: number }
---@param count integer
---@return table<integer, table<string, unknown>>
function SaveEditorPokegearCard.cells(bounds, count)
  return GridCard.resolveGrid({
    bounds = bounds,
    count = count,
    columns = 2,
    rows = 3,
    gap = 8,
    maxWidth = bounds.width,
  })
end

return SaveEditorPokegearCard
