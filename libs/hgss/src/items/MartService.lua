-- Coordinates HGSS shop sessions over the canonical profile, Bag service,
-- and a copied MartSave bucket. No UI, disk, or event ownership lives here.

local PlayerData = require("libs.hgss.src.save.PlayerData")

---@class MartService
---@field private _profile table<string, unknown>
---@field private _bag HgssBagService
---@field private _items ItemCatalog
---@field private _catalog table<string, unknown>
---@field private _bucket table<string, unknown>
---@field private _revision integer
---@field private _active table<string, unknown>?
---@field private _date table<string, unknown>?
local MartService = {}
MartService.__index = MartService

local MAX_STOCK_ENTRIES = 254
local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, child in pairs(value) do
    result[key] = copy(child)
  end
  return result
end

local function integer(value, minimum, maximum)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
    and value % 1 == 0
    and value >= minimum
    and value <= maximum
end

local function checkArray(value, maximum, what)
  assert(type(value) == "table", what .. " must be an array")
  local count = #value
  assert(count <= maximum, what .. " is too long")
  for key in pairs(value) do
    assert(
      type(key) == "number" and key % 1 == 0 and key >= 1 and key <= count,
      what .. " must be a dense ordered array"
    )
  end
  return count
end

local function bit(mask, index)
  return math.floor(mask / (2 ^ index)) % 2 == 1
end

local function setBit(mask, index)
  return bit(mask, index) and mask or mask + 2 ^ index
end

local function popcount(mask)
  local count = 0
  while mask > 0 do
    count = count + mask % 2
    mask = math.floor(mask / 2)
  end
  return count
end

local function dayParts(date)
  assert(
    type(date) == "table" and integer(date.year, 1, 9999) and integer(date.month, 1, 12) and integer(date.day, 1, 31),
    "LocalClock date must be Gregorian"
  )
  local year, month, day = date.year, date.month, date.day
  local leap = year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
  local monthDays = { 31, leap and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  assert(day <= monthDays[month], "LocalClock date has an invalid day of month")
  local prior = year - 1
  local ordinal = prior * 365 + math.floor(prior / 4) - math.floor(prior / 100) + math.floor(prior / 400) + day
  for index = 1, month - 1 do
    ordinal = ordinal + monthDays[index]
  end
  -- 0001-01-01 is Monday in the proleptic Gregorian calendar.
  return ordinal, ordinal % 7
end

local function validateStock(stock, itemCatalog, catalog)
  assert(type(stock) == "table" and type(stock.key) == "string" and stock.key ~= "", "mart stock key is required")
  local stockFields =
    { key = true, currency = true, presentationKind = true, quantityMode = true, bonusPolicy = true, entries = true }
  for key in pairs(stock) do
    assert(stockFields[key], "mart stock has an unknown field " .. tostring(key))
  end
  local modes = {
    items = { currency = "money", quantityMode = "multiple", target = { bag = true } },
    seals = { currency = "money", quantityMode = "multiple", target = { seal = true } },
    legacy_decorations = { currency = "money", quantityMode = "single", target = { unavailable = true } },
    athlete_items = { currency = "athlete_points", quantityMode = "single", target = { bag = true, apricorn = true } },
    athlete_cards = { currency = "athlete_points", quantityMode = "single", target = { card = true } },
  }
  local mode = modes[stock.presentationKind]
  assert(
    mode and mode.currency == stock.currency and mode.quantityMode == stock.quantityMode,
    "mart stock presentation, currency and quantity mode are incompatible"
  )
  assert(stock.bonusPolicy == "none" or stock.bonusPolicy == "premier_ball", "mart stock bonus policy is invalid")
  assert(stock.bonusPolicy ~= "premier_ball" or stock.currency == "money", "Premier Ball bonus requires money stock")
  local entryCount = checkArray(stock.entries, MAX_STOCK_ENTRIES, "mart stock entries")
  local result, seen = copy(stock), {}
  result.entries = {}
  for index = 1, entryCount do
    local entry = stock.entries[index]
    assert(
      type(entry) == "table" and type(entry.key) == "string" and entry.key ~= "" and not seen[entry.key],
      "mart stock entry keys must be unique"
    )
    local entryFields = {
      key = true,
      displayItemKey = true,
      description = true,
      unitPrice = true,
      destination = true,
      restriction = true,
      capacityProbe = true,
    }
    for key in pairs(entry) do
      assert(entryFields[key], "mart entry has an unknown field " .. tostring(key))
    end
    seen[entry.key] = true
    assert(type(entry.displayItemKey) == "string", "mart display item key is required")
    itemCatalog:item(entry.displayItemKey)
    assert(integer(entry.unitPrice, 0, 999999), "mart entry price is invalid")
    assert(type(entry.description) == "table", "mart description is invalid")
    if entry.description.kind == "item" then
      for key in pairs(entry.description) do
        assert(key == "kind", "item description contains an unknown field")
      end
    elseif entry.description.kind == "literal" and type(entry.description.value) == "string" then
      for key in pairs(entry.description) do
        assert(key == "kind" or key == "value", "literal description contains an unknown field")
      end
    else
      error("mart description is invalid", 0)
    end
    for key in pairs(entry.destination) do
      assert(key == "kind" or key == "key", "mart destination contains an unknown field")
    end
    assert(
      type(entry.destination) == "table" and mode.target[entry.destination.kind],
      "mart stock destination is incompatible"
    )
    assert(type(entry.destination.key) == "string" and entry.destination.key ~= "", "mart destination key is invalid")
    if entry.destination.kind == "bag" then
      itemCatalog:item(entry.destination.key)
    elseif entry.destination.kind == "apricorn" then
      assert(catalog.apricorns[entry.destination.key] ~= nil, "unknown Apricorn key")
    elseif entry.destination.kind == "seal" then
      assert(catalog.seals[entry.destination.key] ~= nil, "unknown seal key")
    elseif entry.destination.kind == "card" then
      assert(catalog.cards[entry.destination.key] ~= nil, "unknown Data Card key")
    elseif entry.destination.kind == "unavailable" then
      assert(catalog.decorations[entry.destination.key] ~= nil, "unknown decoration key")
    end
    local restriction = entry.restriction or { kind = "none" }
    assert(
      restriction.kind == "none" or restriction.kind == "daily_slot" or restriction.kind == "owned_card",
      "mart restriction is invalid"
    )
    if restriction.kind == "daily_slot" then
      assert(integer(restriction.slot, 0, 11), "mart daily slot is invalid")
      for key in pairs(restriction) do
        assert(key == "kind" or key == "slot", "daily restriction contains an unknown field")
      end
    elseif restriction.kind == "owned_card" then
      assert(
        entry.destination.kind == "card" and restriction.key == entry.destination.key,
        "owned-card restriction must match its destination"
      )
      for key in pairs(restriction) do
        assert(key == "kind" or key == "key", "owned-card restriction contains an unknown field")
      end
    else
      for key in pairs(restriction) do
        assert(key == "kind", "none restriction contains an unknown field")
      end
    end
    if entry.capacityProbe ~= nil then
      assert(
        entry.destination.kind == "card" and entry.capacityProbe.kind == "bag",
        "only Data Cards use a Bag capacity probe"
      )
      for key in pairs(entry.capacityProbe) do
        assert(key == "kind" or key == "key", "capacity probe contains an unknown field")
      end
      itemCatalog:item(entry.capacityProbe.key)
    end
    if entry.destination.kind == "card" then
      assert(
        restriction.kind == "owned_card" and restriction.key == entry.destination.key,
        "Data Card entries require a matching ownership restriction"
      )
      assert(entry.capacityProbe ~= nil, "Data Card entries require the source Bag capacity probe")
    end
    result.entries[index] = copy(entry)
    result.entries[index].restriction = copy(restriction)
  end
  return result
end

local function sealEquipped(bucket, sealKey)
  local count = 0
  for _, capsule in ipairs(bucket.sealCase.capsules) do
    for _, placed in ipairs(capsule) do
      if placed.key == sealKey then
        count = count + 1
      end
    end
  end
  return count
end

local function sealCount(bucket, sealKey)
  return (bucket.sealCase.loose[sealKey] or 0) + sealEquipped(bucket, sealKey)
end

local function modifyBucket(bucket, entry, quantity, currency, total, catalog)
  local candidate = copy(bucket)
  if currency == "athlete_points" then
    candidate.athletePoints = candidate.athletePoints - total
  end
  candidate.statistics.currencySpent = math.min(999999999, candidate.statistics.currencySpent + total)
  local target = entry.destination
  if target.kind == "apricorn" then
    candidate.apricorns[target.key] = (candidate.apricorns[target.key] or 0) + quantity
  elseif target.kind == "seal" then
    candidate.sealCase.loose[target.key] = (candidate.sealCase.loose[target.key] or 0) + quantity
  elseif target.kind == "card" then
    local card = assert(catalog.cards[target.key], "Data Card metadata exists").ownershipIndex
    assert(
      type(card) == "number" and card % 1 == 0 and card >= 0 and card <= 26,
      "Data Card ownership index is required"
    )
    candidate.ownedDataCardsMask = setBit(candidate.ownedDataCardsMask, card)
  end
  if entry.restriction.kind == "daily_slot" then
    candidate.dailyPurchasedMask = setBit(candidate.dailyPurchasedMask, entry.restriction.slot)
  end
  return candidate
end

local sessionMethods = {}

---@param options table<string, unknown>
---@return MartService
function MartService.new(options)
  assert(type(options) == "table" and type(options.profile) == "table", "MartService requires the canonical profile")
  assert(
    type(options.bag) == "table" and type(options.bag.prepareInventoryChanges) == "function",
    "MartService requires HgssBagService"
  )
  assert(
    type(options.itemCatalog) == "table" and type(options.catalog) == "table",
    "MartService requires both catalogs"
  )
  assert(type(options.bucket) == "table", "MartService requires the persisted mart bucket")
  local bucket = copy(options.bucket)
  return setmetatable({
    _profile = options.profile,
    _bag = options.bag,
    _items = options.itemCatalog,
    _catalog = options.catalog,
    _bucket = bucket,
    _revision = 0,
    _active = nil,
    _date = nil,
  }, MartService)
end

function MartService:capture()
  return copy(self._bucket)
end

function MartService:processDate(date)
  if self._active and not self._active.closed then
    if self._date then
      return copy(self._date)
    end
    return { weekday = 0, dayOrdinal = self._bucket.lastProcessedDay }
  end
  local ordinal, weekday = dayParts(date)
  local candidate = copy(self._bucket)
  if candidate.lastProcessedDay == 0 then
    candidate.lastProcessedDay = ordinal
  elseif ordinal > candidate.lastProcessedDay then
    candidate.dailyPurchasedMask = 0
    candidate.lastProcessedDay = ordinal
  elseif ordinal < candidate.lastProcessedDay then
    candidate.lastProcessedDay = ordinal
  end
  if
    candidate.lastProcessedDay ~= self._bucket.lastProcessedDay
    or candidate.dailyPurchasedMask ~= self._bucket.dailyPurchasedMask
  then
    self._bucket = candidate
    self._revision = self._revision + 1
  end
  self._date = { weekday = weekday, dayOrdinal = ordinal }
  return copy(self._date)
end

function MartService:athleteAvailable(stock)
  assert(type(stock) == "table" and type(stock.entries) == "table", "resolved athlete stock is required")
  return #stock.entries > popcount(self._bucket.dailyPurchasedMask)
end

function MartService:cardPrefix()
  for index = 0, 26 do
    if not bit(self._bucket.ownedDataCardsMask, index) then
      return index
    end
  end
  return 27
end

local function ownedCount(service, entry)
  local target = entry.destination
  if target.kind == "bag" then
    return service._bag:quantity(target.key)
  end
  if target.kind == "apricorn" then
    return service._bucket.apricorns[target.key] or 0
  end
  if target.kind == "seal" then
    return sealCount(service._bucket, target.key)
  end
  if target.kind == "card" then
    return service._bag:quantity(entry.displayItemKey)
  end
  return 0
end

local function failure(service, entry, currency, balance)
  local restriction = entry.restriction
  if entry.destination.kind == "unavailable" then
    return "legacy_unavailable"
  end
  if restriction.kind == "daily_slot" and bit(service._bucket.dailyPurchasedMask, restriction.slot) then
    return "bought_today"
  end
  if restriction.kind == "owned_card" then
    local index = assert(service._catalog.cards[restriction.key]).ownershipIndex
    if bit(service._bucket.ownedDataCardsMask, index) then
      return "already_owned"
    end
  end
  if balance < entry.unitPrice then
    return currency == "money" and "insufficient_money" or "insufficient_points"
  end
  return nil
end

local function sessionView(session)
  local service = session.service
  local balance = session.currency == "money" and service._profile.money or service._bucket.athletePoints
  local view = {
    key = session.stock.key,
    currency = session.currency,
    presentationKind = session.stock.presentationKind,
    quantityMode = session.stock.quantityMode,
    balance = balance,
    entries = {},
  }
  for index, entry in ipairs(session.stock.entries) do
    local owned = ownedCount(service, entry)
    local selectionFailure = failure(service, entry, session.currency, balance)
    local item = service._items:item(entry.displayItemKey)
    local descriptionText = entry.description.kind == "literal" and entry.description.value or item.description
    local maximum = session.stock.quantityMode == "single" and 1
      or (entry.unitPrice == 0 and 99 or math.min(99, math.floor(balance / entry.unitPrice)))
    view.entries[index] = {
      entryKey = entry.key,
      displayItemKey = entry.displayItemKey,
      bindings = { itemName = item.name, pocketName = service._items:pocketName(item.pocket) },
      unitPrice = entry.unitPrice,
      description = copy(entry.description),
      descriptionText = descriptionText,
      priceVisible = selectionFailure ~= "bought_today" and selectionFailure ~= "already_owned",
      ownedQuantity = owned,
      maxQuantity = maximum,
      selectionFailure = selectionFailure,
    }
  end
  return view
end

function MartService:openBuy(stock)
  assert(not self._active or self._active.closed, "a mart session is already active")
  local owned = validateStock(stock, self._items, self._catalog)
  local session = {
    service = self,
    stock = owned,
    currency = owned.currency,
    closed = false,
    bagRevision = self._bag:revision(),
    serviceRevision = self._revision,
  }
  self._active = session
  return setmetatable(session, { __index = sessionMethods })
end

function sessionMethods:view()
  assert(not self.closed, "mart session is closed")
  if self.stock.key == "sell" then
    return {
      key = "sell",
      currency = "money",
      presentationKind = self.stock.presentationKind,
      quantityMode = self.stock.quantityMode,
      balance = self.service._profile.money,
      entries = {},
    }
  end
  return sessionView(self)
end

local function findEntry(session, entryKey)
  for _, entry in ipairs(session.stock.entries) do
    if entry.key == entryKey then
      return entry
    end
  end
end

local function prepareQuote(session, entry, quantity, selling)
  local service = session.service
  -- A new quote attempt replaces the prior transaction identity even when
  -- its request is rejected.
  session.quote, session.receipt, session.receiptState = nil, nil, nil
  local currency = selling and "money" or session.currency
  local balance = currency == "money" and service._profile.money or service._bucket.athletePoints
  if not integer(quantity, 1, 99) or (not selling and session.stock.quantityMode == "single" and quantity ~= 1) then
    return nil, "invalid_quantity"
  end
  local price, delta = entry.unitPrice, {}
  if selling then
    local definition = service._items:item(entry.itemKey)
    if definition.preventToss == true or math.floor(price / 2) == 0 then
      return nil, "not_sellable"
    end
    price = math.floor(price / 2)
    if service._bag:quantity(entry.itemKey) < quantity then
      return nil, "stale"
    end
    delta[1] = { op = "take", item = entry.itemKey, quantity = quantity }
  else
    local reason = failure(service, entry, currency, balance)
    if reason then
      return nil, reason
    end
    if session.stock.quantityMode == "single" and quantity ~= 1 then
      return nil, "invalid_quantity"
    end
    if quantity * price > balance then
      return nil, currency == "money" and "insufficient_money" or "insufficient_points"
    end
    local target = entry.destination
    if target.kind == "bag" then
      delta[1] = { op = "add", item = target.key, quantity = quantity }
    elseif target.kind == "unavailable" then
      return nil, "legacy_unavailable"
    elseif target.kind == "apricorn" and (service._bucket.apricorns[target.key] or 0) + quantity > 99 then
      return nil, "apricorn_full"
    elseif target.kind == "seal" and sealCount(service._bucket, target.key) + quantity > 99 then
      return nil, "seal_full"
    elseif target.kind == "card" then
      if entry.capacityProbe then
        local probe = service._bag:prepareInventoryChanges(service._bag:revision(), {
          { op = "add", item = entry.capacityProbe.key, quantity = 1 },
        })
        if not probe then
          return nil, "bag_full"
        end
      end
    end
  end
  local bagRevision = service._bag:revision()
  local prepared, reason = service._bag:prepareInventoryChanges(bagRevision, delta)
  if not prepared then
    return nil, reason or "stale"
  end
  if not prepared.isCurrent() then
    return nil, "stale"
  end
  local total = price * quantity
  local nextMoney = service._profile.money
  if currency == "money" then
    nextMoney = selling and math.min(PlayerData.MAX_MONEY, nextMoney + total) or nextMoney - total
  end
  local nextBucket
  if not selling then
    nextBucket = modifyBucket(service._bucket, entry, quantity, currency, total, service._catalog)
  elseif currency == "money" then
    nextBucket = copy(service._bucket)
  end
  local terms = {
    quantity = quantity,
    unitPrice = price,
    total = total,
    currency = currency,
    displayItemKey = entry.displayItemKey,
    bindings = {
      itemName = service._items:item(entry.displayItemKey).name,
      pocketName = service._items:pocketName(service._items:item(entry.displayItemKey).pocket),
    },
  }
  local token = {}
  session.quote = {
    token = token,
    terms = copy(terms),
    preparation = prepared,
    bagRevision = bagRevision,
    serviceRevision = service._revision,
    balance = balance,
    nextMoney = nextMoney,
    nextBucket = nextBucket,
    entry = entry,
    quantity = quantity,
    total = total,
    selling = selling,
    currency = currency,
  }
  session.receipt = nil
  return token, copy(terms)
end

function sessionMethods:quoteBuy(entryKey, quantity)
  assert(not self.closed and self.stock.key ~= "sell", "mart buy session is closed or invalid")
  local entry = findEntry(self, entryKey)
  assert(entry, "mart entry key does not belong to this session")
  return prepareQuote(self, entry, quantity, false)
end

function MartService:openSell()
  assert(not self._active or self._active.closed, "a mart session is already active")
  local stock = {
    key = "sell",
    currency = "money",
    presentationKind = "items",
    quantityMode = "multiple",
    bonusPolicy = "none",
    entries = {},
  }
  local session = {
    service = self,
    stock = stock,
    currency = "money",
    closed = false,
    bagRevision = self._bag:revision(),
    serviceRevision = self._revision,
  }
  self._active = session
  return setmetatable(session, { __index = sessionMethods })
end

function sessionMethods:quoteSell(itemKey, quantity)
  assert(not self.closed and self.stock.key == "sell", "mart sell session is closed or invalid")
  self.service._items:item(itemKey)
  local definition = self.service._items:item(itemKey)
  return prepareQuote(self, {
    key = itemKey,
    itemKey = itemKey,
    displayItemKey = itemKey,
    unitPrice = definition.price,
    destination = { kind = "bag", key = itemKey },
    restriction = { kind = "none" },
  }, quantity, true)
end

function sessionMethods:commit(token)
  assert(not self.closed, "mart session is closed")
  local service, quote = self.service, self.quote
  if quote == nil or token ~= quote.token then
    return nil, "stale"
  end
  if self.receipt and token == quote.token then
    return self.receipt
  end
  if
    quote.serviceRevision ~= service._revision
    or quote.bagRevision ~= service._bag:revision()
    or quote.balance ~= (quote.currency == "money" and service._profile.money or service._bucket.athletePoints)
  then
    return nil, "stale"
  end
  if not quote.preparation.isCurrent() then
    return nil, "stale"
  end
  -- All validation and staging finished above. This synchronous section
  -- publishes the Bag candidate and then its already validated peers.
  quote.preparation.publish()
  service._profile.money = quote.nextMoney
  if quote.nextBucket then
    service._bucket = quote.nextBucket
  end
  service._revision = service._revision + 1
  local bonusEligible = not quote.selling
    and quote.currency == "money"
    and quote.quantity >= 10
    and quote.entry.destination.kind == "bag"
    and quote.entry.destination.key == "POKE_BALL"
    and self.stock.bonusPolicy == "premier_ball"
  self.receipt = { terms = copy(quote.terms) }
  self.receiptState =
    { handle = self.receipt, bonusEligible = bonusEligible, acknowledged = false, bonusGranted = false }
  return self.receipt
end

function sessionMethods:acknowledge(receipt)
  local state = self.receiptState
  if self.closed or state == nil or receipt ~= state.handle then
    return nil, "stale"
  end
  if state.acknowledged then
    return { bonusGranted = state.bonusGranted }
  end
  local granted = false
  local candidate
  if state.bonusEligible then
    candidate = copy(self.service._bucket)
    candidate.statistics.premierBallsEarned = math.min(999999, candidate.statistics.premierBallsEarned + 1)
  end
  if state.bonusEligible and self.service._bag:hasSpace("PREMIER_BALL", 1) then
    granted = self.service._bag:add("PREMIER_BALL", 1)
    if granted then
      self.service._bucket = candidate
      self.service._revision = self.service._revision + 1
    end
  end
  state.acknowledged = true
  state.bonusGranted = granted
  return { bonusGranted = granted }
end

function sessionMethods:close()
  if self.closed then
    return
  end
  self.closed, self.quote, self.receipt, self.receiptState = true, nil, nil, nil
  if self.service._active == self then
    self.service._active = nil
  end
end

return MartService
