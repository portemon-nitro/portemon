-- Durable badge and Running Shoes operations over the canonical shared
-- player profile. The progression object borrows the validated profile;
-- awards mutate that shared record in place so saves, menus, and field
-- checks observe one progression truth. Pure domain module: no love dependency and no I/O. Source
-- numeric badge indexes cross only the explicit adapters below, keeping
-- runtime code on semantic badge keys.

---@class PlayerProgression
---@field profile table<string, unknown> the borrowed canonical player profile
local PlayerProgression = {}

-- Semantic badge order: the source's Johto badge indexes 0..7 followed by
-- the Kanto indexes 8..15 (pret/pokeheartgold field_move.c badge gates).
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

PlayerProgression.MAX_MASK = 0xFFFF

local INDEX_BY_KEY = {}
for index, key in ipairs(PlayerProgression.BADGE_ORDER) do
  INDEX_BY_KEY[key] = index - 1
end

local function isMask(value)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
    and value % 1 == 0
    and value >= 0
    and value <= PlayerProgression.MAX_MASK
end

---@param key string
---@return integer
function PlayerProgression.toNativeIndex(key)
  local index = INDEX_BY_KEY[key]
  assert(index ~= nil, "unknown badge key " .. tostring(key))
  return index
end

---@param index integer
---@return string
function PlayerProgression.fromNativeIndex(index)
  local key = PlayerProgression.BADGE_ORDER[index + 1]
  assert(key ~= nil, "unknown badge index " .. tostring(index))
  return key
end

---@param value unknown
---@return boolean
function PlayerProgression.isMask(value)
  return isMask(value)
end

---@param profile table<string, unknown> the canonical shared player profile
---@return PlayerProgression
function PlayerProgression.new(profile)
  assert(type(profile) == "table", "PlayerProgression borrows the validated profile")
  assert(isMask(profile.badges), "profile badges must be a 16-bit mask")
  return setmetatable({ profile = profile }, PlayerProgression)
end

PlayerProgression.__index = PlayerProgression

---@param key string
---@return boolean
function PlayerProgression:hasBadge(key)
  local index = INDEX_BY_KEY[key]
  assert(index ~= nil, "unknown badge key " .. tostring(key))
  return (math.floor(self.profile.badges / (2 ^ index)) % 2) == 1
end

---@param key string
function PlayerProgression:awardBadge(key)
  local index = INDEX_BY_KEY[key]
  assert(index ~= nil, "unknown badge key " .. tostring(key))
  if not self:hasBadge(key) then
    self.profile.badges = self.profile.badges + (2 ^ index)
  end
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
  for _, key in ipairs(PlayerProgression.BADGE_ORDER) do
    if self:hasBadge(key) then
      count = count + 1
    end
  end
  return count
end

return PlayerProgression
