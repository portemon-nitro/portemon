-- Counts the five independent Trainer Card star predicates from HGSS.
local TrainerCardStars = {}

---@class TrainerCardStarsWorld
---@field isFlagSet fun(self: TrainerCardStarsWorld, name: string): boolean

---@class TrainerCardStarsDex
---@field nationalCaughtCount fun(self: TrainerCardStarsDex): integer

---@class TrainerCardStarsFrontier
---@field allAtLeast fun(self: TrainerCardStarsFrontier, threshold: integer): boolean

---@param world TrainerCardStarsWorld
---@param dex TrainerCardStarsDex
---@param frontier TrainerCardStarsFrontier
---@return integer
function TrainerCardStars.count(world, dex, frontier)
  local stars = 0
  if world:isFlagSet("FLAG_GAME_CLEAR") then
    stars = stars + 1
  end
  if dex:nationalCaughtCount() >= 484 then
    stars = stars + 1
  end
  if frontier:allAtLeast(100) then
    stars = stars + 1
  end
  if world:isFlagSet("FLAG_UNK_0F1") then
    stars = stars + 1
  end
  if world:isFlagSet("FLAG_UNK_184") then
    stars = stars + 1
  end
  return stars
end

return TrainerCardStars
