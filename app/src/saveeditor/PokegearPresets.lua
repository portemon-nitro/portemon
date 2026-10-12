-- Bounded reproducible companion scenarios for the save editor. Each named
-- preset declares its preconditions and its ordered change summary, then
-- applies only those facts to a detached record copy through the same
-- validated draft the interactive editor uses. Presets mutate no party,
-- story, or world system beyond the companion bucket and its coherent
-- ownership flag; an incompatible fixture fails with an attributed reason
-- instead of a silent repair, and a scenario needing an absent specialty
-- system stays explicitly unavailable instead of fabricating facts. The
-- inert status reader below only borrows persisted snapshot boundaries:
-- repeated queries draw no random values and alter no state or timing.
-- Scenario catalog module: entries carry only descriptive data
-- (label, preconditions, changes, availability); precondition checks and
-- operation staging live in the validated draft, which preview and apply
-- drive. No love dependency, no runtime access, no closures stored in
-- saves.

local Errors = require("libs.errors.src.Errors")
local SaveEditorPokegearDraft = require("app.src.saveeditor.SaveEditorPokegearDraft")

---@class PokegearPresetChange
---@field fact string
---@field detail string

---@class PokegearPresetDescription
---@field label string
---@field preconditions string[]
---@field changes PokegearPresetChange[]
---@field available boolean
---@field reason string?

---@class PokegearPresetDefinition
---@field label string
---@field preconditions string[]
---@field changes PokegearPresetChange[]
---@field available boolean
---@field reason string?
local PokegearPresets = {}

local PresetError = SaveEditorPokegearDraft.PresetError
local UNAVAILABLE = PresetError.UNAVAILABLE
local PRECONDITION = PresetError.PRECONDITION
local UNKNOWN = PresetError.UNKNOWN

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

-- The closed precondition vocabulary behind scenario declarations: every
-- preset lists only these names, and definition lookup validates
-- membership so a misspelled precondition fails loudly instead of
-- printing an invented requirement.
local PRECONDITIONS = {
  ["the companion record exists"] = true,
  ["the Elm caller is registered"] = true,
  ["no Elm trigger waits"] = true,
  ["the radio card is registered"] = true,
  ["the rematch caller is registered"] = true,
  ["the gift caller is registered"] = true,
  ["the marking location is catalogued"] = true,
  ["the Safari Zone caller system is composed"] = true,
}
local PRESETS = {
  ["before-mom-gear"] = {
    label = "Before Mom holds the savings",
    preconditions = { "the companion record exists" },
    changes = {
      { fact = "pokegear.phone.mom", detail = "restores an empty savings balance with no queued gifts" },
      { fact = "pokegear.registeredCards", detail = "keeps only the base companion card" },
    },
  },
  ["before-elm-call"] = {
    label = "Before the Elm call",
    preconditions = { "the Elm caller is registered", "no Elm trigger waits" },
    changes = {
      { fact = "pokegear.phone.triggers", detail = "clears the waiting Elm trigger" },
      { fact = "pokegear.phone.contacts", detail = "keeps the Elm caller with no pending reward" },
    },
  },
  ["after-cherrygrove-map"] = {
    label = "After the Cherrygrove Map",
    preconditions = { "the companion record exists" },
    changes = {
      { fact = "pokegear.registeredCards", detail = "registers the map card with coherent ownership" },
      { fact = "pokegear.mapUnlockLevel", detail = "opens the first region tier" },
    },
  },
  ["before-goldenrod-quiz"] = {
    label = "Before the Goldenrod radio quiz",
    preconditions = { "the radio card is registered" },
    changes = {
      { fact = "pokegear.registeredCards", detail = "registers the radio card with coherent ownership" },
      { fact = "pokegear.radioCursor", detail = "parks the tuner on the quiz station" },
    },
  },
  ["johto-clear-radio"] = {
    label = "Johto clear radio",
    preconditions = { "the radio card is registered" },
    changes = {
      { fact = "pokegear.registeredCards", detail = "registers the radio card with coherent ownership" },
      { fact = "pokegear.radioCursor", detail = "parks the tuner for clear reception" },
    },
  },
  ["rockets-active"] = {
    label = "Rockets active on the airwaves",
    preconditions = { "the radio card is registered" },
    changes = {
      { fact = "pokegear.registeredCards", detail = "registers the radio card with coherent ownership" },
      { fact = "pokegear.phone.triggers", detail = "raises the active Rockets broadcast trigger" },
    },
  },
  ["mahogany-uncleared"] = {
    label = "Mahogany withheld",
    preconditions = { "the companion record exists" },
    changes = {
      { fact = "pokegear.mapUnlockLevel", detail = "holds the region tier below Mahogany" },
    },
  },
  ["mahogany-cleared"] = {
    label = "Mahogany cleared",
    preconditions = { "the companion record exists" },
    changes = {
      { fact = "pokegear.mapUnlockLevel", detail = "opens the region tier past Mahogany" },
    },
  },
  ["kanto-before-power"] = {
    label = "Kanto before the power plant",
    preconditions = { "the companion record exists" },
    changes = {
      { fact = "pokegear.mapUnlockLevel", detail = "holds the region tier below the Kanto expansion" },
    },
  },
  ["kanto-after-power"] = {
    label = "Kanto after the power plant",
    preconditions = { "the companion record exists" },
    changes = {
      { fact = "pokegear.mapUnlockLevel", detail = "opens the region tier past the Kanto power plant" },
    },
  },
  ["kanto-expn-spotlight"] = {
    label = "Kanto EXPN spotlight",
    preconditions = { "the radio card is registered" },
    changes = {
      { fact = "pokegear.registeredCards", detail = "registers the radio card with coherent ownership" },
      { fact = "pokegear.radioCursor", detail = "parks the tuner on the EXPN spotlight" },
    },
  },
  ["eligible-trainer-rematch"] = {
    label = "Eligible trainer rematch",
    preconditions = { "the rematch caller is registered" },
    changes = {
      { fact = "pokegear.phone.rematches", detail = "stages the eligible rematch record" },
    },
  },
  ["pending-gift"] = {
    label = "Pending gift",
    preconditions = { "the gift caller is registered" },
    changes = {
      { fact = "pokegear.phone.contacts", detail = "stages the pending gift for the caller" },
    },
  },
  ["marked-word-location"] = {
    label = "Marked location with a word",
    preconditions = { "the marking location is catalogued" },
    changes = {
      { fact = "pokegear.markings", detail = "marks the location with an icon and a word" },
    },
  },
  ["safari-call-standby"] = {
    label = "Safari call standby",
    preconditions = { "the Safari Zone caller system is composed" },
    changes = {
      { fact = "pokegear.phone.triggers", detail = "would raise the Safari standby trigger" },
    },
    available = false,
    reason = "The Safari Zone caller system is not composed in this build, so the standby trigger stays unavailable.",
  },
}

local ORDER = {
  "before-mom-gear",
  "before-elm-call",
  "after-cherrygrove-map",
  "before-goldenrod-quiz",
  "johto-clear-radio",
  "rockets-active",
  "mahogany-uncleared",
  "mahogany-cleared",
  "kanto-before-power",
  "kanto-after-power",
  "kanto-expn-spotlight",
  "eligible-trainer-rematch",
  "pending-gift",
  "marked-word-location",
  "safari-call-standby",
}

---@param name string
---@return PokegearPresetDefinition definition
local function definitionFor(name)
  if type(name) ~= "string" then
    Errors.raise(UNKNOWN, "Companion scenarios are named by behaviour.", { name = name })
  end
  local definition = PRESETS[name]
  if definition == nil then
    Errors.raise(UNKNOWN, "Unknown companion scenario " .. name .. ".", { name = name })
  end
  assert(type(definition) == "table", "scenario names resolve to their definition")
  assert(type(definition.preconditions) == "table", "scenario definitions declare their preconditions")
  for _, precondition in ipairs(definition.preconditions) do
    assert(
      PRECONDITIONS[precondition] == true,
      "scenario preconditions stay inside the closed vocabulary: " .. tostring(precondition)
    )
  end
  return definition
end

---@param refs unknown
local function checkRefs(refs)
  if type(refs) ~= "table" or type(refs.catalog) ~= "table" then
    Errors.raise(PRECONDITION, "Companion scenarios require contact and location references.", {})
  end
end

---@return string[] behaviour names in presentation order
function PokegearPresets.names()
  return copy(ORDER) --[[@as string[] ]]
end

---@param name string
---@return PokegearPresetDescription the declared preconditions and ordered change summary
function PokegearPresets.describe(name)
  local definition = definitionFor(name)
  return {
    label = definition.label,
    preconditions = copy(definition.preconditions) --[[@as string[] ]],
    changes = copy(definition.changes) --[[@as PokegearPresetChange[] ]],
    available = definition.available ~= false,
    reason = definition.reason,
  }
end

---@param name string
---@param refs table<string, unknown>
---@return PokegearPresetChange[]? preview
---@return Errors.Error? error
function PokegearPresets.preview(name, refs)
  local ok, previewOrError = pcall(function()
    local definition = definitionFor(name)
    checkRefs(refs)
    assert(type(refs) == "table", "scenario previews read catalog references")
    if definition.available == false then
      Errors.raise(UNAVAILABLE, definition.reason or "This scenario is unavailable.", { name = name })
    end
    -- Resolving catalog keys now keeps missing-asset failures in the
    -- preview instead of inventing facts at apply time.
    SaveEditorPokegearDraft.presetOps(name, refs)
    return copy(definition.changes)
  end)
  if not ok then
    if Errors.is(previewOrError) then
      return nil, previewOrError --[[@as Errors.Error]]
    end
    error(previewOrError, 0)
  end
  return previewOrError, --[[@as PokegearPresetChange[] ]]
    nil
end

---@param name string
---@param record table<string, unknown>
---@param refs table<string, unknown>
---@return table<string, unknown>? updated
---@return Errors.Error? error
function PokegearPresets.applyToRecord(name, record, refs)
  local ok, updatedOrError = pcall(function()
    local definition = definitionFor(name)
    checkRefs(refs)
    assert(type(refs) == "table", "scenario application reads catalog references")
    if type(record) ~= "table" then
      Errors.raise(PRECONDITION, "Companion scenarios apply to a save record.", {})
    end
    if definition.available == false then
      Errors.raise(UNAVAILABLE, definition.reason or "This scenario is unavailable.", { name = name })
    end
    local draft = SaveEditorPokegearDraft.new({ record = copy(record), refs = refs })
    draft:changePreset(name)
    local updated, applyError = draft:apply()
    if updated == nil then
      error(assert(applyError), 0)
    end
    assert(type(updated) == "table", "validated scenarios return their updated record")
    updated.__presetSummary = nil
    return updated
  end)
  if not ok then
    if Errors.is(updatedOrError) then
      return nil, updatedOrError --[[@as Errors.Error]]
    end
    error(updatedOrError, 0)
  end
  return updatedOrError, --[[@as table<string, unknown> ]]
    nil
end

-- Reads the inert companion debug record: the persisted minute checkpoint,
-- the ring state, the accepted caller, the effect latch, the shown program,
-- the reception signal, and the state revision. Every value comes from
-- already-persisted snapshots or the caller's signals; the query draws no
-- random values and alters no state, timing, or clock.
---@param gear table<string, unknown> the durable companion owner
---@param signals { ring: string?, acceptedCaller: unknown, effectLatch: string?, showId: unknown, signal: string? }?
---@return table<string, unknown>
function PokegearPresets.statusSnapshot(gear, signals)
  assert(type(gear) == "table", "status queries read the companion owner")
  local readCalendar = gear.readCalendar --[[@as fun(self: table<string, unknown>): table<string, unknown>]]
  assert(type(readCalendar) == "function", "status queries read the persisted calendar")
  local revisionOf = gear.revision --[[@as fun(self: table<string, unknown>): integer]]
  assert(type(revisionOf) == "function", "status queries read the persisted revision")
  local calendar = readCalendar(gear)
  assert(type(calendar) == "table", "status queries copy the calendar record")
  local observed = signals or {}
  assert(type(observed) == "table", "status queries read their signal record")
  return {
    minuteCheckpoint = copy(calendar.checkpoint),
    daySerial = calendar.daySerial,
    ring = observed.ring,
    caller = observed.acceptedCaller,
    acceptedCaller = observed.acceptedCaller,
    latch = observed.effectLatch,
    effectLatch = observed.effectLatch,
    show = observed.showId,
    showId = observed.showId,
    signal = observed.signal,
    revision = revisionOf(gear),
  }
end

return PokegearPresets
