-- Default HGSS stock policy and custom policy replacement tests.

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
  return {
    normalTiers = normalTiers,
    specialStocks = specialStocks,
    athleteStocks = athleteStocks,
    dataCardStocks = dataCardStocks,
    sealStocks = { {}, {}, {}, {}, {}, {}, {} },
    decorationStocks = { {}, {} },
    cards = cards,
    apricorns = { RED_APRICORN = "red" },
    seals = {},
    decorations = {},
  }
end

local function context(overrides)
  local value = {
    badges = 0,
    nationalDex = false,
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
    local expectedCounts = { [1] = 3, [2] = 7, [3] = 11, [4] = 15, [5] = 17, [6] = 18 }
    local stock = resolve({ kind = "standard" }, context({ badges = mask, nationalDex = false }))
    Assert.equal(#stock.entries, expectedCounts[tier], "badge count " .. badgeCount .. " selects tier " .. tier)
    for _, entry in ipairs(stock.entries) do
      Assert.isFalse(entry.displayItemKey == "POKE_BALL", "standard stock omits the tutorial Pokeball")
    end
  end
  local noFilter = resolve({ kind = "standard" }, context({
    badges = 0,
    nationalDex = false,
    readFlag = function() return false end,
  }))
  Assert.equal(noFilter.entries[1].displayItemKey, "POKE_BALL")
end

function T.special_filter_does_not_change_other_selectors_or_custom_stock()
  local source = catalog()
  local specialFiltered = resolve({ kind = "special", selector = 4 }, context(), source)
  Assert.equal(#specialFiltered.entries, 0)
  local specialOther = resolve({ kind = "special", selector = 3 }, context(), source)
  Assert.equal(#specialOther.entries, 1)
  local customInput = {
    key = "addon-stock",
    currency = "money",
    presentationKind = "items",
    quantityMode = "multiple",
    bonusPolicy = "none",
    entries = {
      { key = "first", displayItemKey = "POKE_BALL", description = { kind = "item" }, unitPrice = 0, destination = { kind = "bag", key = "POKE_BALL" }, restriction = { kind = "none" } },
      { key = "second", displayItemKey = "POKE_BALL", description = { kind = "literal", value = "offer" }, unitPrice = 7, destination = { kind = "bag", key = "POKE_BALL" }, restriction = { kind = "none" } },
    },
  }
  local stock = resolve({ kind = "custom", stock = customInput }, context(), source)
  customInput.entries[1].unitPrice = 999
  Assert.equal(#stock.entries, 2)
  Assert.equal(stock.entries[1].key, "first")
  Assert.equal(stock.entries[1].unitPrice, 0)
  Assert.equal(stock.entries[2].unitPrice, 7)
  Assert.equal(stock.entries[1].destination.key, "POKE_BALL")
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
