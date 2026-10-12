-- HGSS vanilla stock selection and source policy tests.

local Assert = require("tests.support.Assert")
local ItemFixture = require("libs.items.tests.item_fixture")
local VanillaMartStock = require("game.hgss.src.mart.VanillaMartStock")

local T = {}

local function catalog()
  local normalTiers = {}
  for index = 1, 19 do
    local itemKey = index == 1 and "POKE_BALL" or "POTION"
    normalTiers[index] = { itemKey = itemKey, minimumTier = index == 19 and 6 or math.ceil(index / 4) }
  end
  local specialStocks = {}
  for selector = 0, 29 do
    specialStocks[selector + 1] = { { subjectKey = selector == 4 and "POKE_BALL" or "POTION", price = { kind = "catalog" } } }
  end
  local athleteStocks = {}
  for index = 1, 14 do
    athleteStocks[index] = { { subjectKey = "POTION", price = { kind = "fixed", value = index } } }
  end
  local dataCardStocks = {}
  for index = 1, 5 do
    dataCardStocks[index] = {}
  end
  local cards = {}
  for ownershipIndex = 0, 26 do
    local itemKey = "ITEM_" .. (ownershipIndex + 30)
    cards[itemKey] = { itemKey = itemKey, ownershipIndex = ownershipIndex }
  end
  local result = {
    normalTiers = normalTiers,
    specialStocks = specialStocks,
    athleteStocks = athleteStocks,
    dataCardStocks = dataCardStocks,
    sealStocks = {},
    decorationStocks = { {}, {} },
    cards = cards,
    apricorns = { RED_APRICORN = "red" },
    seals = {},
    decorations = {},
  }
  for selector = 0, 6 do
    local sealKey = "SEAL_" .. selector
    result.sealStocks[selector + 1] = {
      { subjectKey = sealKey, price = { kind = "catalog" } },
    }
    result.seals[sealKey] = { displayItemKey = "POTION", description = sealKey }
  end
  return result
end

local function context(overrides)
  local value = {
    badges = 0,
    nationalDex = false,
    runningShoes = false,
    runningShoesLock = false,
    weekday = 0,
    dayOrdinal = 1,
    cardPrefix = 0,
    readFlag = function(flag)
      return flag == 0x09A
    end,
    readVariable = function()
      return 0
    end,
  }
  for key, replacement in pairs(overrides or {}) do
    value[key] = replacement
  end
  return value
end

local function resolve(descriptor, facts, sourceCatalog)
  local items = ItemFixture.makeCatalog()
  return VanillaMartStock.resolve(descriptor, facts or context(), { mart = sourceCatalog or catalog(), items = items })
end

function T.standard_stock_uses_all_six_badge_tiers_and_filters_only_pokeball()
  for badgeCount = 0, 16 do
    local mask = badgeCount == 0 and 0 or (0x8000 + 2 ^ (badgeCount - 1) - 1)
    local tier = badgeCount == 0 and 1 or badgeCount <= 2 and 2 or badgeCount <= 4 and 3
      or badgeCount <= 6 and 4 or badgeCount == 7 and 5 or 6
    local expectedCounts = { [1] = 4, [2] = 8, [3] = 12, [4] = 16, [5] = 18, [6] = 19 }
    local hidden = resolve({ kind = "standard" }, context({
      badges = mask,
      nationalDex = false,
      runningShoes = false,
      runningShoesLock = false,
      readFlag = function() return false end,
    }))
    local shown = resolve({ kind = "standard" }, context({
      badges = mask,
      nationalDex = false,
      runningShoes = false,
      runningShoesLock = false,
      readFlag = function() return true end,
    }))
    Assert.equal(#hidden.entries, expectedCounts[tier] - 1, "false flag excludes Poké Ball")
    Assert.equal(#shown.entries, expectedCounts[tier], "true flag retains the source tier size")
    Assert.equal(hidden.entries[1].displayItemKey, "POTION", "false flag removes the leading Poké Ball")
    Assert.equal(shown.entries[1].displayItemKey, "POKE_BALL", "true flag includes the leading Poké Ball")
    local hiddenNonBalls, shownNonBalls = {}, {}
    for _, entry in ipairs(hidden.entries) do
      if entry.displayItemKey ~= "POKE_BALL" then hiddenNonBalls[#hiddenNonBalls + 1] = entry.displayItemKey end
    end
    for _, entry in ipairs(shown.entries) do
      if entry.displayItemKey ~= "POKE_BALL" then shownNonBalls[#shownNonBalls + 1] = entry.displayItemKey end
    end
    Assert.deepEqual(hiddenNonBalls, shownNonBalls, "flag preserves all other entries and their order")
  end
end

function T.special_filter_follows_flag_and_leaves_lists_without_pokeballs_unchanged()
  local source = catalog()
  local hiddenBall = resolve({ kind = "special", selector = 4 }, context({ readFlag = function() return false end }), source)
  local shownBall = resolve({ kind = "special", selector = 4 }, context({ readFlag = function() return true end }), source)
  local hiddenPlain = resolve({ kind = "special", selector = 3 }, context({ readFlag = function() return false end }), source)
  local shownPlain = resolve({ kind = "special", selector = 3 }, context({ readFlag = function() return true end }), source)
  Assert.equal(#hiddenBall.entries, 0, "false flag excludes the special Poké Ball")
  Assert.equal(shownBall.entries[1].displayItemKey, "POKE_BALL", "true flag includes the special Poké Ball")
  Assert.deepEqual(shownPlain, hiddenPlain, "flag does not affect a special list without Poké Ball")
end

function T.every_seal_entry_uses_the_fixed_retail_price()
  local source = catalog()
  local aliasPrice = ItemFixture.makeCatalog():item("POTION").price
  Assert.isFalse(aliasPrice == 100, "the fixture alias price differs from the retail Seal price")
  for selector = 0, 6 do
    local seals = resolve({ kind = "seal", selector = selector }, nil, source)
    Assert.equal(#seals.entries, 1)
    Assert.equal(seals.entries[1].displayItemKey, "POTION")
    Assert.equal(seals.entries[1].unitPrice, 100, "Seal selector " .. selector .. " uses the fixed price")
  end
end

function T.athlete_and_card_selection_use_weekday_dex_and_first_gap()
  for weekday = 0, 6 do
    local ordinary = resolve({ kind = "athlete" }, context({ weekday = weekday, nationalDex = false }))
    local dex = resolve({ kind = "athlete" }, context({ weekday = weekday, nationalDex = true }))
    Assert.equal(ordinary.entries[1].unitPrice, weekday + 1)
    Assert.equal(dex.entries[1].unitPrice, weekday + 8)
  end
  local cardCatalog = catalog()
  for group = 0, 4 do
    for offset = 0, 5 do
      local ownershipIndex = group * 6 + offset
      if ownershipIndex <= 26 then
        cardCatalog.dataCardStocks[group + 1][offset + 1] = {
          subjectKey = "ITEM_" .. (ownershipIndex + 30),
          price = { kind = "fixed", value = ownershipIndex },
        }
      end
    end
  end
  for _, prefix in ipairs({ 0, 5, 6, 11, 12, 23, 24, 26, 27 }) do
    local stock = resolve({ kind = "data_cards" }, context({ cardPrefix = prefix }), cardCatalog)
    local group = math.floor(prefix / 6)
    Assert.equal(#stock.entries, group == 4 and 3 or 6)
    for index, entry in ipairs(stock.entries) do
      Assert.notNil(entry.restriction, "ownership restrictions stay attached to source card identity")
      Assert.isNil(entry.ownershipIndex, "resolved entries keep the normative field contract")
      Assert.equal(entry.displayItemKey, "ITEM_" .. (group * 6 + index - 1 + 30))
    end
  end
end

return { tests = T }
