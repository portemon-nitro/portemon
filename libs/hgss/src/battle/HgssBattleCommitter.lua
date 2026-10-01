-- Concrete battle result publication: stages every affected owner before
-- publishing, then installs all candidates in one synchronous,
-- non-yielding sequence exactly once per outcome. Callers hand over
-- already-staged preparations (party, bag, dex knowledge), detached
-- records (party updates, captures, rewards, player money facts, roamer
-- outcomes), and the live party owner when captures must be placed. The
-- committer validates everything during preparation; a preparation
-- failure changes no live owner, and a commit failure before publication
-- leaves every owner on its last known-good state. Repeating a
-- completion returns the recorded receipt instead of publishing twice, so
-- reward money, ball consumption, party insertion, caught knowledge, and
-- roamer updates never duplicate. No callbacks run between the owner
-- swaps; there is no generic transaction framework here, only the ordered
-- use of the existing owners. Durable saving stays with the save
-- pipeline, which receives the validated player candidate through the
-- receipt.

local HgssSendToPcStub = require("libs.hgss.src.battle.HgssSendToPcStub")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local Party = require("libs.mons.src.Party")
local PlayerData = require("libs.hgss.src.save.PlayerData")

---@class HgssBattleCommitter
local HgssBattleCommitter = {}

-- Fallback level for bare capture results that name a species but carry
-- no caught record and no level. Callers with real battle data pass the
-- full caught mon, which keeps its own level; this default only keeps the
-- species-only path total.
HgssBattleCommitter.FALLBACK_CAPTURE_LEVEL = 5

---@type table<string, table<string, unknown>>
local RECEIPTS = {}

---@param owner unknown
---@return boolean
local function isPartyOwner(owner)
  return type(owner) == "table"
    and type(owner.partyCount) == "function"
    and type(owner.partyRevision) == "function"
    and type(owner.preparePartyBatch) == "function"
end

---@param preparation unknown
---@param what string
local function checkPreparation(preparation, what)
  if type(preparation) ~= "table" then
    error("battle commit " .. what .. " must be a staged preparation", 0)
  end
  local prep = preparation --[[@as { isCurrent: unknown, publish: unknown }]]
  if type(prep.isCurrent) ~= "function" or type(prep.publish) ~= "function" then
    error("battle commit " .. what .. " must expose currency and publication", 0)
  end
  local current = prep.isCurrent()
  if current ~= true then
    error("battle commit " .. what .. " is stale", 0)
  end
end

---@param outcome unknown
---@return string
local function checkOutcome(outcome)
  if type(outcome) ~= "table" then
    error("battle commit requires an outcome record", 0)
  end
  if type(outcome.id) ~= "string" or outcome.id == "" then
    error("battle commit requires a non-empty outcome id", 0)
  end
  if type(outcome.result) ~= "string" or outcome.result == "" then
    error("battle commit requires an outcome result", 0)
  end
  return outcome.id
end

---@param explicit unknown
---@return HgssMonService?
local function resolveOwner(explicit)
  if explicit ~= nil then
    if not isPartyOwner(explicit) then
      error("battle commit party owner must stage party batches", 0)
    end
    return explicit --[[@as HgssMonService]]
  end
  local owners = HgssMonService.liveOwners()
  if #owners == 0 then
    return nil
  end
  return owners[1]
end

---@generic T
---@param value T
---@return T
local function copyValue(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = copyValue(item)
  end
  return out
end

---@param capture unknown
---@param index integer
---@return table<string, unknown>?
local function checkCapture(capture, index)
  if type(capture) ~= "table" then
    error("battle commit capture " .. tostring(index) .. " must be a record", 0)
  end
  local entry = capture --[[@as table<string, unknown>]]
  if entry.success ~= true and entry.success ~= false then
    error("battle commit capture " .. tostring(index) .. " carries a success flag", 0)
  end
  if entry.success ~= true then
    return nil
  end
  if entry.mon ~= nil and type(entry.mon) ~= "table" then
    error("battle commit capture " .. tostring(index) .. " carries a mon record when present", 0)
  end
  if entry.mon == nil and type(entry.species) ~= "string" then
    error("battle commit capture " .. tostring(index) .. " names a species without a mon record", 0)
  end
  return entry
end

---@param level unknown
---@return integer
local function captureLevel(level)
  if type(level) == "number" and level % 1 == 0 and level >= 1 and level <= 100 then
    return level
  end
  return HgssBattleCommitter.FALLBACK_CAPTURE_LEVEL
end

-- Stages every affected owner and validates the detached records without
-- publishing anything. The returned preparation is committed once through
-- commit; repeating commit reuses the recorded receipt.
---@param args { outcome: { id: string, result: string }, party: table<string, unknown>?, bag: table<string, unknown>?, dex: table<string, unknown>?, partyOwner: table<string, unknown>?, partyUpdates: { slot: integer, mon: table<string, unknown> }[]?, captures: table<string, unknown>[]?, rewards: table<string, unknown>?, scriptFlags: table<string, unknown>?, player: { record: table<string, unknown>, context: table<string, unknown>, moneyDelta: integer? }?, roamer: { owner: table<string, unknown>, key: string, outcome: string, expectedRevision: integer, details: table<string, unknown> }?, stale: boolean? }
---@return table<string, unknown>
function HgssBattleCommitter.prepare(args)
  if type(args) ~= "table" then
    error("battle commit preparation requires an argument record", 0)
  end
  local outcomeId = checkOutcome(args.outcome)
  if args.stale == true then
    error("battle commit preparation found a stale owner revision", 0)
  end
  if args.party ~= nil then
    checkPreparation(args.party, "party candidate")
  end
  if args.bag ~= nil then
    checkPreparation(args.bag, "bag candidate")
  end
  if args.dex ~= nil then
    checkPreparation(args.dex, "dex candidate")
  end
  local updates = args.partyUpdates or {}
  if type(updates) ~= "table" then
    error("battle commit party updates must be an array when present", 0)
  end
  local captures = {}
  local attempts = 0
  if args.captures ~= nil then
    if type(args.captures) ~= "table" then
      error("battle commit captures must be an array when present", 0)
    end
    for index, capture in ipairs(args.captures) do
      attempts = attempts + 1
      local entry = checkCapture(capture, index)
      if entry ~= nil then
        captures[#captures + 1] = entry
      end
    end
  end
  local owner = nil
  if #updates > 0 or #captures > 0 then
    owner = resolveOwner(args.partyOwner)
    if owner == nil then
      error("battle commit captures and party updates need a party owner", 0)
    end
  end
  if args.party ~= nil and owner ~= nil then
    error("battle commit stages party updates and captures through one batch", 0)
  end
  local ownerBatch = nil
  local appends = {}
  if owner ~= nil then
    for _, entry in ipairs(captures) do
      if entry.mon ~= nil then
        appends[#appends + 1] = entry.mon
      else
        -- Unknown species fail here, before any publication, through a
        -- read-only lookup that mutates nothing.
        owner:countSpecies(entry.species)
      end
    end
    if #updates > 0 or #appends > 0 then
      if owner:partyCount() + #appends > Party.MAX then
        error("battle commit capture appends exceed the party", 0)
      end
      local batch, reason = owner:preparePartyBatch(owner:partyRevision(), updates, appends)
      if batch == nil then
        error("battle commit party batch went stale: " .. tostring(reason), 0)
      end
      ownerBatch = batch
    end
  end
  local playerCandidate = nil
  if args.player ~= nil then
    if type(args.player) ~= "table" then
      error("battle commit player changes must be a record when present", 0)
    end
    playerCandidate = PlayerData.prepareBattleChanges(args.player.record, args.player.context, {
      moneyDelta = args.player.moneyDelta or 0,
    })
  end
  local roamer = args.roamer
  if roamer ~= nil then
    if type(roamer) ~= "table" or type(roamer.owner) ~= "table" then
      error("battle commit roamer outcomes name their owning state", 0)
    end
  end
  if
    args.party == nil
    and args.bag == nil
    and args.dex == nil
    and ownerBatch == nil
    and attempts == 0
    and args.rewards == nil
    and args.player == nil
    and roamer == nil
  then
    error("battle commit preparation stages at least one result", 0)
  end
  local staged = {
    outcomeId = outcomeId,
    outcome = copyValue(args.outcome),
    party = args.party,
    bag = args.bag,
    dex = args.dex,
    owner = owner,
    ownerBatch = ownerBatch,
    captures = captures,
    rewards = copyValue(args.rewards),
    scriptFlags = copyValue(args.scriptFlags) or {},
    playerCandidate = playerCandidate,
    roamer = roamer,
  }
  return staged --[[@as CommitPreparation]]
end

---@class CommitPreparation
---@field outcomeId string
---@field outcome table<string, unknown>
---@field party { isCurrent: fun(): boolean, publish: fun() }?
---@field bag { isCurrent: fun(): boolean, publish: fun() }?
---@field dex { isCurrent: fun(): boolean, publish: fun() }?
---@field owner HgssMonService?
---@field ownerBatch { isCurrent: fun(): boolean, publish: fun() }?
---@field captures table<string, unknown>[]
---@field rewards table<string, unknown>?
---@field scriptFlags table<string, unknown>
---@field playerCandidate table<string, unknown>?
---@field roamer { owner: table<string, unknown>, key: string, outcome: string, expectedRevision: integer, details: table<string, unknown> }?

---@param preparation unknown
---@param what string
---@return (fun())?
local function checkedPublish(preparation, what)
  if preparation == nil then
    return nil
  end
  checkPreparation(preparation, what)
  local prep = preparation --[[@as { publish: fun() }]]
  local publish = prep.publish
  assert(type(publish) == "function", "battle commit " .. what .. " publishes")
  return publish
end

---@param owner HgssMonService
---@param entry table<string, unknown>
---@return table<string, unknown>
local function placeUnplaced(owner, entry)
  local placement = HgssSendToPcStub.send({ species = entry.species }, {
    partyCount = owner:partyCount(),
    captureId = entry.captureId,
  })
  placement.captureId = entry.captureId
  return placement
end

---@param prepared CommitPreparation
---@return table<string, unknown>
function HgssBattleCommitter.commit(prepared)
  if type(prepared) ~= "table" or type(prepared.outcomeId) ~= "string" then
    error("battle commit consumes a staged preparation", 0)
  end
  assert(type(prepared) == "table", "commit reads its staged preparation")
  local staged = prepared --[[@as CommitPreparation]]
  local recorded = RECEIPTS[staged.outcomeId]
  if recorded ~= nil then
    return recorded
  end
  local publishParty = checkedPublish(staged.party, "party candidate")
  local publishBag = checkedPublish(staged.bag, "bag candidate")
  local publishDex = checkedPublish(staged.dex, "dex candidate")
  local publishBatch = checkedPublish(staged.ownerBatch, "party batch")
  -- The fallible roamer writeback runs before any owner swap, so its
  -- rejection leaves every live owner on the last known-good state.
  local roamerResult = nil
  if staged.roamer ~= nil then
    local roamerOwner = staged.roamer.owner
    local apply = roamerOwner.prepareResult
    assert(type(apply) == "function", "roamer outcomes commit through their owner")
    roamerResult = apply(
      roamerOwner,
      staged.roamer.key,
      staged.roamer.outcome,
      staged.roamer.expectedRevision,
      staged.roamer.details
    )
  end
  if publishParty ~= nil then
    publishParty()
  end
  if publishBag ~= nil then
    publishBag()
  end
  if publishDex ~= nil then
    publishDex()
  end
  if publishBatch ~= nil then
    publishBatch()
  end
  local placements = {}
  local owner = staged.owner
  if owner ~= nil then
    -- Staged record appends land first as one contiguous tail in capture
    -- order, so their slots are known before the species-only leftovers.
    local recordAppends = 0
    for _, entry in ipairs(staged.captures) do
      if entry.mon ~= nil then
        recordAppends = recordAppends + 1
      end
    end
    local recordSlot = owner:partyCount() - recordAppends
    for _, entry in ipairs(staged.captures) do
      if entry.mon ~= nil then
        placements[#placements + 1] = {
          captureId = entry.captureId,
          retained = true,
          destination = "party",
          partySlot = recordSlot,
          reason = "retained",
        }
        recordSlot = recordSlot + 1
      else
        local slot = owner:partyCount()
        local added = false
        if slot < Party.MAX then
          added = owner:giveMon({ species = entry.species, level = captureLevel(entry.level) })
        end
        if added then
          placements[#placements + 1] = {
            captureId = entry.captureId,
            retained = true,
            destination = "party",
            partySlot = slot,
            reason = "retained",
          }
        else
          placements[#placements + 1] = placeUnplaced(owner, entry)
        end
      end
    end
  end
  local receipt = {
    outcomeId = staged.outcomeId,
    committed = true,
    placements = placements,
    rewards = copyValue(staged.rewards),
    scriptFlags = copyValue(staged.scriptFlags),
    player = copyValue(staged.playerCandidate),
    roamer = copyValue(roamerResult),
  }
  RECEIPTS[staged.outcomeId] = receipt
  return receipt
end

-- Returns the recorded receipt for a committed outcome, or nil when the
-- outcome never committed (including preparations that failed before
-- publication).
---@param outcomeId string
---@return table<string, unknown>?
function HgssBattleCommitter.receipt(outcomeId)
  return RECEIPTS[outcomeId]
end

return HgssBattleCommitter
