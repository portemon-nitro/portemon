-- Durable badge and Running Shoes operations over the canonical shared
-- player profile. Badges are an open key-value set: profile.badges maps a
-- non-empty string key to true, so modded regions with their own gym
-- counts work without bit-field surgery, and every owned key counts
-- equally. The sixteen retail keys below stay only as the canonical
-- migration and native-index adapters so retail scripts keep resolving.
-- The progression object borrows the validated profile; awards mutate that
-- shared record in place so saves, menus, and field checks observe one
-- progression truth. Pure domain module: no love dependency and no I/O.
-- Source numeric badge indexes cross only the explicit adapters below,
-- keeping runtime code on open string keys.

---@class PlayerProgression
---@field profile table<string, unknown> the borrowed canonical player profile
local PlayerProgression = {}

-- Canonical retail badge keys in source numeric order: Johto 0..7 followed
-- by Kanto 8..15. Migration and the native-index adapters below are the
-- only places that pair these keys with bit positions.
PlayerProgression.BADGE_ORDER = {
  "zephyr",
  "hive",
  "plain",
  "fog",
  "storm",
  "mineral",
  "glacier",
  "rising",
  "boulder",
  "cascade",
  "thunder",
  "rainbow",
  "soul",
  "marsh",
  "volcano",
  "earth",
}

local INDEX_BY_KEY = {}
for index, key in ipairs(PlayerProgression.BADGE_ORDER) do
  INDEX_BY_KEY[key] = index - 1
end

---@param key unknown
---@return boolean
local function isKey(key)
  return type(key) == "string" and key ~= ""
end

---@param value unknown
---@return boolean
local function isBadgeSet(value)
  if type(value) ~= "table" then
    return false
  end
  for key, owned in pairs(value) do
    if not isKey(key) or owned ~= true then
      return false
    end
  end
  return true
end

---@param key string
---@return integer
function PlayerProgression.toNativeIndex(key)
  local index = INDEX_BY_KEY[key]
  assert(index ~= nil, "unknown retail badge key " .. tostring(key))
  return index
end

---@param index integer
---@return string
function PlayerProgression.fromNativeIndex(index)
  local key = PlayerProgression.BADGE_ORDER[index + 1]
  assert(key ~= nil, "unknown retail badge index " .. tostring(index))
  return key
end

---@param value unknown
---@return boolean
function PlayerProgression.isBadgeSet(value)
  return isBadgeSet(value)
end

---@param profile table<string, unknown> the canonical shared player profile
---@return PlayerProgression
function PlayerProgression.new(profile)
  assert(type(profile) == "table", "PlayerProgression borrows the validated profile")
  assert(isBadgeSet(profile.badges), "profile badges must be an open badge set")
  return setmetatable({ profile = profile }, PlayerProgression)
end

PlayerProgression.__index = PlayerProgression

---@param key string
---@return boolean
function PlayerProgression:hasBadge(key)
  assert(isKey(key), "badge keys are non-empty strings, got " .. tostring(key))
  return self.profile.badges[key] == true
end

---@param key string
function PlayerProgression:awardBadge(key)
  assert(isKey(key), "badge keys are non-empty strings, got " .. tostring(key))
  self.profile.badges[key] = true
end

---@return boolean
function PlayerProgression:hasRunningShoes()
  return self.profile.runningShoes == true
end

-- The Start Menu auto-run lock: while set (and the shoes are owned) the
-- player runs without holding B.
---@return boolean
function PlayerProgression:runningShoesLock()
  return self.profile.runningShoesLock == true
end

-- Flips the auto-run lock; only reachable once the shoes are owned.
function PlayerProgression:toggleRunningShoesLock()
  assert(self:hasRunningShoes(), "the Running Shoes lock needs the shoes")
  self.profile.runningShoesLock = not self.profile.runningShoesLock
end

-- Idempotent Running Shoes gift on the shared profile.
function PlayerProgression:awardRunningShoes()
  self.profile.runningShoes = true
end

---@return integer
function PlayerProgression:badgeCount()
  local count = 0
  for _, owned in pairs(self.profile.badges) do
    if owned == true then
      count = count + 1
    end
  end
  return count
end

return PlayerProgression
