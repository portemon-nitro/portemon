-- The generated asset bytes a committed compile produces live in memory, not
-- on disk: one compact byte owner prepares a whole batch privately, publishes
-- it in one non-yielding commit, and lends the identical LÖVE Data buffer to
-- every reader until it is closed. Nothing here knows job keys, ROM identity,
-- or eviction: it owns immutable bytes and their visibility only.

local Assert = require("tests.support.Assert")

local T = {}

local SOURCE_ID = "base:probe-generation"
local VERSION = "resident-probe"

---@return table
local function requireResidentCache()
  local ok, resident = pcall(require, "libs.storage.src.ResidentCache")
  Assert.isTrue(
    ok and resident ~= nil and type(resident.new) == "function",
    "no resident generated-byte owner exists to publish compiled output in memory: " .. tostring(resident)
  )
  return resident --[[@as table]]
end

local function byteData(text)
  return assert(love.data.newByteData(text), "the probe needs a real LÖVE Data buffer")
end

---@param path string
---@param text string
---@return table entry
local function entry(path, text)
  return {
    path = path,
    data = byteData(text),
    size = #text,
    sourceId = SOURCE_ID,
    contentId = "probe-generation\0" .. path,
  }
end

local function newOwner()
  return requireResidentCache().new(VERSION, SOURCE_ID)
end

-- A refused preparation may report a typed failure or raise; either way the
-- batch must not reach the visible mapping.
local function assertRefused(fn, message)
  local ok, result = pcall(fn)
  Assert.isTrue(not ok or result == nil, message)
end

-- Compiled output becomes reachable only through one commit: a prepared batch
-- that is never committed publishes nothing, and the bytes a reader gets back
-- are the very buffer the owner committed rather than a serialized copy.
function T.committed_bytes_are_visible_only_after_one_commit()
  local owner = newOwner()
  local scene = entry("data/generated/field/30/scene.lua", "return { mapId = 30 }\n")
  local atlas = entry("assets/generated/field/30/atlas.png", "PNGDATA")

  local prepared = assert(owner:prepare({ scene, atlas }), "a confined batch prepares")
  Assert.isNil(owner:resolveAsset(scene.path), "a prepared entry is not visible before its commit")
  Assert.isNil(owner:readData(scene.path), "a prepared entry lends no bytes before its commit")
  Assert.equal(#owner:paths(""), 0, "an uncommitted batch adds no visible path")

  owner:commit(prepared)
  local resolved = assert(owner:resolveAsset(scene.path), "a committed entry resolves")
  Assert.equal(resolved.sourceId, SOURCE_ID, "the resolved reference carries the store's source identity")
  Assert.equal(resolved.path, scene.path, "the resolved reference names its logical path")
  Assert.equal(resolved.size, scene.size, "the resolved reference reports its payload size")
  Assert.isTrue(resolved.path:find("^data/generated/") ~= nil, "a resident path stays a logical generated path")

  local borrowed = assert(owner:readData(scene.path), "a committed entry lends its bytes")
  Assert.isTrue(borrowed == resolved.data, "the resolved reference and the lent bytes are one buffer, never a copy")
  Assert.equal(borrowed:getSize(), scene.size, "the lent buffer reports the committed payload size")
  Assert.equal(borrowed:getString(), scene.data:getString(), "the lent buffer holds the committed bytes")
  Assert.isTrue(owner:readData(atlas.path) == atlas.data, "every committed entry lends its own buffer")

  local listed = owner:paths("data/generated/")
  Assert.equal(#listed, 1, "a prefix lists only the entries beneath it")
  Assert.equal(listed[1], scene.path, "the prefix list carries the logical path")
  Assert.equal(#owner:paths(""), 2, "the whole store lists both generated roots")
  owner:close()
end

-- A batch that a producer got wrong must change nothing: unconfined or
-- duplicate paths and a foreign source identity are refused while the already
-- committed entries keep serving their bytes.
function T.rejected_preparation_leaves_committed_bytes_untouched()
  local owner = newOwner()
  local committed = entry("data/generated/field/31/scene.lua", "committed")
  owner:commit(owner:prepare({ committed }))
  local stable = assert(owner:resolveAsset(committed.path), "the baseline entry is visible")

  local traversal = entry("data/generated/../../saves/heartgold/game.lua", "escape")
  assertRefused(function()
    return owner:prepare({ traversal })
  end, "a path escaping the generated roots must be refused")
  Assert.equal(#owner:paths(""), 1, "a refused batch adds no entry")
  Assert.equal(owner:readData(committed.path):getString(), "committed", "a refused batch keeps committed bytes")

  local duplicate = entry(committed.path, "shadow")
  assertRefused(function()
    return owner:prepare({ committed, duplicate })
  end, "one batch cannot carry the same logical path twice")

  local foreign = entry("data/generated/field/31/other.lua", "other")
  foreign.sourceId = "base:someone-else"
  assertRefused(function()
    return owner:prepare({ foreign })
  end, "entries from another generation may not enter this store")

  local outsideRoot = entry("saves/heartgold/game.lua", "not generated")
  assertRefused(function()
    return owner:prepare({ outsideRoot })
  end, "a path outside the generated roots is not a resident entry")

  local aliased = entry("data/generated/field/31/../31/scene.lua", "aliased")
  assertRefused(function()
    return owner:prepare({ aliased })
  end, "an aliased path must not address a resident entry")

  local embeddedNul = entry("data/generated/field/31/scene.lua\0.png", "nul")
  assertRefused(function()
    return owner:prepare({ embeddedNul })
  end, "a path with an embedded NUL is refused")

  local misreported = entry("data/generated/field/31/short.lua", "longer than claimed")
  misreported.size = 3
  assertRefused(function()
    return owner:prepare({ misreported })
  end, "an entry whose size contradicts its buffer is refused")

  -- A batch is prepared as a whole: one bad entry publishes none of its
  -- neighbours either.
  local goodNeighbour = entry("data/generated/field/31/new.lua", "new")
  assertRefused(function()
    return owner:prepare({ goodNeighbour, embeddedNul })
  end, "one rejected entry refuses the whole batch")
  Assert.isNil(owner:resolveAsset(goodNeighbour.path), "a refused batch publishes no part of itself")

  Assert.isTrue(owner:resolveAsset(committed.path) == stable, "the committed reference is unchanged")
  owner:close()
end

-- Closing revokes new lookups without invalidating what a consumer already
-- borrowed: readers that outlive retirement finish their work on the bytes
-- they hold, and a second close is a no-op.
function T.close_revokes_new_lookups_and_keeps_borrowed_bytes_readable()
  local owner = newOwner()
  local scene = entry("data/generated/field/32/scene.lua", "borrowed")
  owner:commit(owner:prepare({ scene }))
  local borrowed = assert(owner:readData(scene.path), "the consumer borrows its bytes while the view is live")

  owner:close()
  Assert.isNil(owner:resolveAsset(scene.path), "a closed view resolves nothing new")
  Assert.isNil(owner:readData(scene.path), "a closed view lends nothing new")
  Assert.equal(#owner:paths(""), 0, "a closed view lists nothing")
  Assert.equal(borrowed:getString(), "borrowed", "the borrowed buffer stays readable after retirement")

  owner:close()
  Assert.isNil(owner:readData(scene.path), "closing twice stays closed")
end

return { tests = T }
