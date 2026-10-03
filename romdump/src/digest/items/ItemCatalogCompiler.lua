-- Source decode and semantic normalization of item data. item_data
-- members follow struct ItemData in include/item.h
-- (pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981): a u16
-- price, the hold-effect byte, and the packed bitfield u16 at offset 8
-- (naturalGiftType:5, prevent_toss:1, selectable:1, fieldPocket:4,
-- battlePocket:5 from the least-significant bit). Member selection follows
-- the ITEMNARC_PARAM column of src/item.c sItemNarcIds. Display text comes
-- through the existing message decoder at the src/message_format.c and
-- src/item.c banks (descriptions 221, names 222, indefinite names 223,
-- plural names 224, pocket names 226, berry names 251). TM/HM mapping
-- follows src/item.c TMHMGetMove over sTMHMMoves. No LOVE objects or
-- filesystem writes; callers publish through ItemCacheWriter.

local BinaryReader = require("libs.codec.src.BinaryReader")
local Errors = require("libs.errors.src.Errors")
local ItemSources = require("romdump.src.config.ItemSources")
local ItemAssetSchema = require("libs.assets.src.ItemAssetSchema")
local ItemCache = require("libs.assets.src.ItemCache")
local FieldMessageBank = require("romdump.src.digest.ui.FieldMessageBank")
local FieldMessageTokenizer = require("romdump.src.digest.ui.FieldMessageTokenizer")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local charmap = require("romdump.src.reference.hgss.charmap")
local Hashing = require("romdump.src.digest.Hashing")
local PngWriter = require("libs.assets.src.PngWriter")
local ItemPresentationCompiler = require("romdump.src.digest.items.ItemPresentationCompiler")

---@class ItemCatalogCompiler
local ItemCatalogCompiler = {}

---@generic T
---@param value T?
---@param err unknown?
---@return T
local function must(value, err)
  if value == nil then
    error(err, 0)
  end
  return value
end

local function contextLabel(context)
  return (context and context.archive or "?") .. " member " .. tostring(context and context.memberId)
end

local function checkSize(member, expected, code, context)
  if #member ~= expected then
    return nil,
      Errors.new(code, contextLabel(context) .. " is " .. #member .. " bytes, expected " .. expected, {
        archive = context.archive,
        memberId = context.memberId,
        size = #member,
        expected = expected,
      })
  end
  return true
end

---@param archive Narc
---@param memberId integer
---@param alias string
---@return string|nil, Errors.Error|nil
local function readMember(archive, memberId, alias)
  local member, err = archive:readMember(memberId)
  if not member then
    if Errors.is(err) then
      local failure = err --[[@as Errors.Error]]
      return nil, failure
    end
    return nil,
      Errors.new(
        "ITEM_MEMBER_MISSING",
        alias .. " member " .. memberId .. " is absent",
        { alias = alias, memberId = memberId }
      )
  end
  return member
end

-- Decode one 34-byte item_data member into the catalog-consumed facts: the
-- hold-effect byte driving friendship behavior, the toss/selectability
-- flags, the field pocket, and the party-use facts. The party parameter
-- bytes follow struct ItemPartyParam in include/item.h: flag bytes carry
-- slp/psn/brn/frz/prz/cfs/inf/guard_spec, revive/revive_all/level_up/evolve
-- plus four-bit battle stages, pp_up/pp_max/pp_restore/pp_restore_all plus
-- hp_restore and the six effort flags, then the three friendship band
-- flags; signed effort/friendship deltas and u8 restore parameters follow.
-- Source sentinels stay producer-side; the catalog stores only normalized
-- partyUse records built by normalizePartyUse below.
---@param member string
---@param context Errors.Context|nil
---@return table<string, unknown>|nil, Errors.Error|nil
function ItemCatalogCompiler.decodeItemData(member, context)
  context = context or {}
  local ok, sizeErr = checkSize(member, ItemSources.ITEM_DATA_SIZE, "ITEM_DATA_BAD_SIZE", context)
  if not ok then
    return nil, sizeErr
  end
  local reader = BinaryReader.new(member, contextLabel(context))
  local word = reader:u16le(ItemSources.ITEM_DATA_BITFIELD_OFFSET)
  local tossBit = 2 ^ ItemSources.ITEM_DATA_PREVENT_TOSS_BIT
  local selectBit = 2 ^ ItemSources.ITEM_DATA_SELECTABLE_BIT
  local pocketShift = 2 ^ ItemSources.ITEM_DATA_FIELD_POCKET_SHIFT
  local paramBase = ItemSources.ITEM_DATA_PARTY_PARAM_OFFSET
  local function flag(index)
    return string.byte(member, paramBase + index + 1)
  end
  local function has(index, bit)
    return math.floor(flag(index) / (2 ^ bit)) % 2 == 1
  end
  local function signed(index)
    local byte = string.byte(member, paramBase + index + 1)
    if byte >= 128 then
      return byte - 256
    end
    return byte
  end
  local b1, b2, b3, b4 = flag(1), flag(2), flag(3), flag(4)
  return {
    holdEffect = string.byte(member, ItemSources.ITEM_DATA_HOLD_EFFECT_OFFSET + 1),
    naturalGiftPower = reader:u8(7),
    preventToss = math.floor(word / tossBit) % 2 == 1,
    selectable = math.floor(word / selectBit) % 2 == 1,
    fieldPocket = math.floor(word / pocketShift) % (ItemSources.ITEM_DATA_FIELD_POCKET_MASK + 1),
    partyUse = string.byte(member, ItemSources.ITEM_DATA_PARTY_USE_OFFSET + 1) == 1,
    party = {
      slpHeal = has(0, 0),
      psnHeal = has(0, 1),
      brnHeal = has(0, 2),
      frzHeal = has(0, 3),
      przHeal = has(0, 4),
      cfsHeal = has(0, 5),
      infHeal = has(0, 6),
      guardSpec = has(0, 7),
      revive = has(1, 0),
      reviveAll = has(1, 1),
      levelUp = has(1, 2),
      evolve = has(1, 3),
      atkStages = math.floor(b1 / 16) % 16,
      defStages = b2 % 16,
      spatkStages = math.floor(b2 / 16) % 16,
      spdefStages = b3 % 16,
      speedStages = math.floor(b3 / 16) % 16,
      accuracyStages = b4 % 16,
      critrateStages = math.floor(b4 / 16) % 4,
      ppUp = has(4, 6),
      ppMax = has(4, 7),
      ppRestore = has(5, 0),
      ppRestoreAll = has(5, 1),
      hpRestore = has(5, 2),
      hpEvUp = has(5, 3),
      atkEvUp = has(5, 4),
      defEvUp = has(5, 5),
      speedEvUp = has(5, 6),
      spatkEvUp = has(5, 7),
      spdefEvUp = has(6, 0),
      friendshipLo = has(6, 1),
      friendshipMed = has(6, 2),
      friendshipHi = has(6, 3),
      hpEvDelta = signed(7),
      atkEvDelta = signed(8),
      defEvDelta = signed(9),
      speedEvDelta = signed(10),
      spatkEvDelta = signed(11),
      spdefEvDelta = signed(12),
      hpRestoreParam = string.byte(member, paramBase + 13 + 1),
      ppRestoreParam = string.byte(member, paramBase + 14 + 1),
      friendshipLoParam = signed(15),
      friendshipMedParam = signed(16),
      friendshipHiParam = signed(17),
    },
  }
end

-- Fixed effort-stat mapping shared by family presence and payload
-- construction. Order matches the generated changes array; decoded
-- flag/delta names follow decodeItemData above.
---@type {stat:string, flag:string, delta:string}[]
local EV_FIELDS = {
  { stat = "hp", flag = "hpEvUp", delta = "hpEvDelta" },
  { stat = "attack", flag = "atkEvUp", delta = "atkEvDelta" },
  { stat = "defense", flag = "defEvUp", delta = "defEvDelta" },
  { stat = "speed", flag = "speedEvUp", delta = "speedEvDelta" },
  { stat = "specialAttack", flag = "spatkEvUp", delta = "spatkEvDelta" },
  { stat = "specialDefense", flag = "spdefEvUp", delta = "spdefEvDelta" },
}

-- Status-cure mapping shared by family presence and the medicine payload.
-- Every key is always present in the built cures record.
---@type {flag:string, cure:string}[]
local CURE_FIELDS = {
  { flag = "slpHeal", cure = "sleep" },
  { flag = "psnHeal", cure = "poison" },
  { flag = "brnHeal", cure = "burn" },
  { flag = "frzHeal", cure = "freeze" },
  { flag = "przHeal", cure = "paralysis" },
}

-- Battle-stage fields below always decode to numbers; their sum only
-- detects battle-only riders and never opens a party family.
local BATTLE_STAGE_FIELDS = {
  "atkStages",
  "defStages",
  "spatkStages",
  "spdefStages",
  "speedStages",
  "accuracyStages",
  "critrateStages",
}

-- Power-point payload with the current operation precedence: boost before
-- max before restore. Friendship attaches once at the ordinary return
-- below, never here.
---@param party table<string, unknown>
---@param mood integer
---@param fail fun(code:string, message:string)
---@return table<string, unknown>
local function ppRecord(party, mood, fail)
  local record = { kind = "pp", target = "one", mood = mood }
  if party.ppUp == true then
    record.boost = 1
  elseif party.ppMax == true then
    record.boost = 3
  else
    if party.ppRestoreAll == true then
      record.target = "all"
    end
    local param = assert(party.ppRestoreParam) --[[@as integer]]
    if param == ItemSources.PP_RESTORE_ALL then
      record.restore = "full"
    elseif param >= 1 and param < ItemSources.PP_RESTORE_ALL then
      record.restore = param
    else
      fail("ITEM_PARTY_EFFECT_INVALID", "carries an invalid power-point restore amount")
    end
  end
  return record
end

-- Effort payload in the fixed stat order above. Friendship attaches once
-- at the ordinary return below, never here.
---@param party table<string, unknown>
---@param mood integer
---@param fail fun(code:string, message:string)
---@return table<string, unknown>
local function evRecord(party, mood, fail)
  local changes = {}
  for _, field in ipairs(EV_FIELDS) do
    if party[field.flag] == true then
      local delta = assert(party[field.delta]) --[[@as integer]]
      if delta == 0 or delta < -100 or delta > 100 then
        fail("ITEM_PARTY_EFFECT_INVALID", "carries an out-of-range effort delta")
      end
      changes[#changes + 1] = { stat = field.stat, delta = delta }
    end
  end
  return { kind = "ev", changes = changes, mood = mood }
end

-- Medicine payload covering ordinary cures, revival, restoration, and the
-- flagged-but-effectless shape. Friendship attaches once at the ordinary
-- return below, never here.
---@param party table<string, unknown>
---@param mood integer
---@param fail fun(code:string, message:string)
---@return table<string, unknown>
local function medicineRecord(party, mood, fail)
  local cures = {}
  for _, field in ipairs(CURE_FIELDS) do
    cures[field.cure] = party[field.flag] == true
  end
  local record = { kind = "medicine", cures = cures, revive = "none", mood = mood }
  if party.revive == true then
    record.revive = "single"
  end
  if party.hpRestore == true then
    local param = assert(party.hpRestoreParam) --[[@as integer]]
    if param == ItemSources.HP_RESTORE_ALL then
      record.restore = { kind = "full" }
    elseif param == ItemSources.HP_RESTORE_HALF then
      record.restore = { kind = "half" }
    elseif param == ItemSources.HP_RESTORE_QTR then
      record.restore = { kind = "quarter" }
    elseif param >= 1 and param < ItemSources.HP_RESTORE_QTR then
      record.restore = { kind = "fixed", amount = param }
    else
      fail("ITEM_PARTY_EFFECT_INVALID", "carries an invalid health restore amount")
    end
  end
  return record
end

-- Normalize decoded party parameters into the closed semantic partyUse
-- record the runtime consumes. Machine, mail, and key-recognized form
-- items resolve without the party-use byte; every other item needs it.
-- Deferred kinds name the explicitly unimplemented behavior. Party
-- families resolve before battle-only riders: confusion/infatuation cure
-- bits riding on full-heal items map to ordinary medicine, while items
-- with no party family but battle-only flags defer explicitly. Flagged
-- but effectless records stay medicinal and never apply. Mixed primary
-- families fail the build instead of guessing a combination the source
-- menu never offers.
---@param nativeId integer
---@param key string
---@param pocketKey string
---@param isMachine boolean
---@param decoded table<string, unknown>
---@return table<string, unknown>
local function normalizePartyUse(nativeId, key, pocketKey, isMachine, decoded)
  local context = { archive = "item_data", memberId = ItemSources.itemDataMember(nativeId) }
  local function fail(code, message)
    error(Errors.new(code, "item " .. key .. " " .. message, context), 0)
  end
  if isMachine then
    return { kind = "machine" }
  end
  if pocketKey == "mail" then
    return { kind = "deferred", reason = "mail" }
  end
  if ItemSources.PARTY_FORM_CHANGE_KEYS[key] then
    return { kind = "deferred", reason = "form_change" }
  end
  local party = assert(decoded.party) --[[@as table<string, unknown>]]
  if not decoded.partyUse then
    return { kind = "none" }
  end
  if party.levelUp == true then
    return { kind = "deferred", reason = "level_up" }
  end
  if party.evolve == true then
    return { kind = "deferred", reason = "evolution" }
  end
  local stages = 0
  for _, name in ipairs(BATTLE_STAGE_FIELDS) do
    stages = stages + party[name] --[[@as integer]]
  end
  local battleOnly = party.guardSpec == true or party.cfsHeal == true or party.infHeal == true or stages ~= 0
  if party.reviveAll == true then
    return { kind = "revive_all" }
  end
  local mood = ItemSources.PARTY_MOOD_BY_KEY[key] or 0
  local friendship = nil
  if party.friendshipLo == true or party.friendshipMed == true or party.friendshipHi == true then
    friendship = {
      lo = party.friendshipLoParam,
      med = party.friendshipMedParam,
      hi = party.friendshipHiParam,
    }
  end
  -- Party-applicable families resolve first; confusion/infatuation cure
  -- bits riding on full-heal items and any other battle-only riders stay
  -- out of the mapped record. Battle-only deferral applies only when no
  -- party family maps. Presence shares the field mappings above with
  -- payload construction, so each family is counted exactly once.
  local hasCure = false
  for _, field in ipairs(CURE_FIELDS) do
    if party[field.flag] == true then
      hasCure = true
      break
    end
  end
  local hasMedicine = hasCure or party.hpRestore == true or party.revive == true
  local hasPp = party.ppUp == true or party.ppMax == true or party.ppRestore == true or party.ppRestoreAll == true
  local hasEv = false
  for _, field in ipairs(EV_FIELDS) do
    if party[field.flag] == true then
      hasEv = true
      break
    end
  end
  local families = 0
  if hasMedicine then
    families = families + 1
  end
  if hasPp then
    families = families + 1
  end
  if hasEv then
    families = families + 1
  end
  if families > 1 then
    fail("ITEM_PARTY_EFFECT_CONFLICT", "carries flags from several effect families")
  end
  if families == 0 then
    if battleOnly then
      return { kind = "deferred", reason = "battle_only" }
    end
    -- Flagged but effectless records stay medicinal and never apply.
  end
  -- Exactly one ordinary family below; the conflict check above keeps
  -- mixed records out. Friendship attaches once after the selected
  -- payload is built, never inside each family branch.
  local record
  if hasPp then
    record = ppRecord(party, mood, fail)
  elseif hasEv then
    record = evRecord(party, mood, fail)
  else
    record = medicineRecord(party, mood, fail)
  end
  if friendship ~= nil then
    record.friendship = friendship
  end
  return record
end

---@param romFs RomFs
---@param alias string
---@return Narc|nil, Errors.Error|nil
local function openArchive(romFs, alias)
  local archive, err = romFs:openNarc(alias)
  if not archive then
    if Errors.is(err) then
      local failure = err --[[@as Errors.Error]]
      return nil, failure
    end
    return nil, Errors.new("ITEM_ARCHIVE_UNAVAILABLE", "item archive " .. alias .. " is unavailable", { alias = alias })
  end
  return archive
end

-- Decode one display-text bank into its message texts indexed by native id.
-- Banks are selected by ItemSources.messageBanks; every message must
-- tokenize.
---@param messagesNarc Narc
---@param bankId integer
---@param expectedCount integer
---@param label string
---@return table<integer, string>|nil, Errors.Error|nil
local function decodeTextBank(messagesNarc, bankId, expectedCount, label)
  local member, memberErr = messagesNarc:readMember(bankId)
  if not member then
    return nil, memberErr
  end
  local bank, bankErr = FieldMessageBank.decode(member, { label = label })
  if not bank then
    return nil, bankErr
  end
  if #bank.messages ~= expectedCount then
    return nil,
      Errors.new(
        "ITEM_TEXT_COUNT_MISMATCH",
        label .. " carries " .. #bank.messages .. " messages, expected " .. expectedCount,
        {
          bankId = bankId,
          count = #bank.messages,
          expected = expectedCount,
        }
      )
  end
  local texts = {}
  for index, message in ipairs(bank.messages) do
    local tokens, tokenErr = FieldMessageTokenizer.tokenize(message.raw, charmap, {})
    if not tokens then
      local failure = assert(tokenErr) --[[@as Errors.Error]]
      failure.context = failure.context or {}
      failure.context.bankId = bankId
      failure.context.messageId = index - 1
      return nil, failure
    end
    texts[index - 1] = FieldMessageText.tokensToText(tokens)
  end
  return texts
end

---@param texts table<integer, string>
---@param id integer
---@param what string
---@param context Errors.Context
---@return string|nil, Errors.Error|nil
local function requireText(texts, id, what, context)
  local text = texts[id]
  if type(text) ~= "string" or text == "" then
    return nil,
      Errors.new("ITEM_TEXT_MISSING", contextLabel(context) .. " has no " .. what .. " text for id " .. id, {
        archive = context.archive,
        memberId = context.memberId,
        id = id,
      })
  end
  return text
end

-- Compile the complete semantic catalog from a supported dump. Every source
-- item identity 0..536 becomes one source-independent definition; pocket,
-- TM/HM, mail, and berry cross-checks fail the build instead of emitting
-- inconsistent data.
---@param romFs RomFs
---@param opts table<string, unknown>|nil
---@return table<string, unknown>|nil, Errors.Error|string|nil
function ItemCatalogCompiler.compileCatalog(romFs, opts)
  opts = opts or {}
  local versionId = opts.versionId or romFs:version()
  local language = ItemSources.versionLanguages[versionId]
  if language == nil then
    return nil,
      Errors.new("ITEM_VERSION_UNSUPPORTED", "item catalog has no language for version " .. tostring(versionId), {
        versionId = versionId,
      })
  end
  local itemData, err = openArchive(romFs, "item_data")
  if not itemData then
    return nil, err
  end
  local messages
  messages, err = openArchive(romFs, "messages")
  if not messages then
    return nil, err
  end
  local ok, result = pcall(function()
    local banks = ItemSources.messageBanks
    local counts = ItemSources.messageCounts
    local descriptions = must(decodeTextBank(messages, banks.description, counts.description, "item descriptions"))
    local names = must(decodeTextBank(messages, banks.name, counts.name, "item names"))
    local indefinites =
      must(decodeTextBank(messages, banks.nameIndefinite, counts.nameIndefinite, "item indefinite names"))
    local plurals = must(decodeTextBank(messages, banks.namePlural, counts.namePlural, "item plural names"))
    local pocketTexts = must(decodeTextBank(messages, banks.pocket, counts.pocket, "pocket names"))
    local berryTexts = must(decodeTextBank(messages, banks.berry, counts.berry, "berry names"))
    local pocketNames = {}
    for pocketId = 0, 7 do
      local pocketKey = must(ItemSources.pocketKeys[pocketId])
      pocketNames[pocketKey] =
        must(requireText(pocketTexts, pocketId, "pocket name", { archive = "messages", memberId = banks.pocket }))
    end
    local items = {}
    for nativeId = 0, 536 do
      local key = ItemSources.itemKeys[nativeId]
      if key == nil then
        error(
          Errors.new("ITEM_UNKNOWN_IDENTITY", "source item identity " .. nativeId .. " has no semantic key", {
            nativeId = nativeId,
          }),
          0
        )
      end
      if items[key] ~= nil then
        error(Errors.new("ITEM_DUPLICATE_KEY", "source item key " .. key .. " is defined twice", { key = key }), 0)
      end
      local memberId = ItemSources.itemDataMember(nativeId)
      local member = must(readMember(itemData, memberId, "item_data"))
      local decoded = must(ItemCatalogCompiler.decodeItemData(member, { archive = "item_data", memberId = memberId }))
      local pocketKey = ItemSources.pocketKeys[decoded.fieldPocket]
      if pocketKey == nil then
        error(
          Errors.new(
            "ITEM_UNKNOWN_POCKET",
            "source item identity " .. nativeId .. " selects unknown pocket " .. decoded.fieldPocket,
            {
              nativeId = nativeId,
              pocket = decoded.fieldPocket,
            }
          ),
          0
        )
      end
      local isMachine = nativeId >= ItemSources.FIRST_TM and nativeId <= ItemSources.LAST_HM
      if (pocketKey == "tmhm") ~= isMachine then
        error(
          Errors.new(
            "ITEM_POCKET_MISMATCH",
            "source item identity " .. nativeId .. " disagrees on TM/HM pocket membership",
            {
              nativeId = nativeId,
              pocket = pocketKey,
            }
          ),
          0
        )
      end
      local isBerry = nativeId >= ItemSources.FIRST_BERRY and nativeId <= ItemSources.LAST_BERRY
      if (pocketKey == "berries") ~= isBerry then
        error(
          Errors.new(
            "ITEM_POCKET_MISMATCH",
            "source item identity " .. nativeId .. " disagrees on berry pocket membership",
            {
              nativeId = nativeId,
              pocket = pocketKey,
            }
          ),
          0
        )
      end
      local isMail = nativeId >= ItemSources.FIRST_MAIL and nativeId <= ItemSources.LAST_MAIL
      if (pocketKey == "mail") ~= isMail then
        error(
          Errors.new(
            "ITEM_POCKET_MISMATCH",
            "source item identity " .. nativeId .. " disagrees on mail pocket membership",
            {
              nativeId = nativeId,
              pocket = pocketKey,
            }
          ),
          0
        )
      end
      local context = { archive = "item_data", memberId = memberId }
      local isHm = nativeId >= ItemSources.FIRST_HM and nativeId <= ItemSources.LAST_HM
      local heldFormEffect = "none"
      if nativeId == ItemSources.GRISEOUS_ORB_ID then
        heldFormEffect = "griseous_orb"
      elseif nativeId >= ItemSources.FIRST_PLATE and nativeId <= ItemSources.LAST_PLATE then
        heldFormEffect = "arceus_plate"
      end
      local record = {
        nativeId = nativeId,
        name = must(requireText(names, nativeId, "item name", context)),
        nameIndefinite = must(requireText(indefinites, nativeId, "item indefinite name", context)),
        namePlural = must(requireText(plurals, nativeId, "item plural name", context)),
        description = descriptions[nativeId],
        pocket = pocketKey,
        preventToss = decoded.preventToss,
        selectable = decoded.selectable,
        isBall = ItemSources.ballItemIds[nativeId] == true,
        friendshipBoost = decoded.holdEffect == ItemSources.HOLD_EFFECT_FRIENDSHIP_UP,
        icon = key,
        isHm = isHm,
        canHold = pocketKey ~= "key_items" and pocketKey ~= "mail" and not isHm,
        heldFormEffect = heldFormEffect,
        partyUse = normalizePartyUse(nativeId, key, pocketKey, isMachine, decoded),
        naturalGiftPower = decoded.naturalGiftPower,
      }
      if type(record.description) ~= "string" then
        error(Errors.new("ITEM_TEXT_MISSING", "item " .. nativeId .. " has no description", { nativeId = nativeId }), 0)
      end
      if isMachine then
        local machine = must(ItemSources.machineMoves[nativeId - ItemSources.FIRST_TM])
        record.tmhmMoveNativeId = machine.nativeId
      end
      if isBerry then
        local berryName = must(requireText(berryTexts, nativeId - ItemSources.FIRST_BERRY, "berry name", context))
        record.berryNameSingular = berryName
        record.berryNamePlural = berryName
      end
      items[key] = record
    end
    local catalog = {
      schema = ItemCache.CATALOG_SCHEMA,
      version = { id = versionId, language = language },
      items = items,
      pockets = ItemCache.POCKETS,
      pocketNames = pocketNames,
    }
    must(ItemAssetSchema.assertCatalog(catalog))
    return catalog
  end)
  if not ok then
    if Errors.is(result) then
      return nil, result
    end
    error(result, 0)
  end
  return result
end

-- Compile the complete publishable class: catalog plus the icon atlas
-- inputs, manifest, content hashes, and the completion marker. Every catalog
-- icon selector must resolve to a manifest entry before the bundle leaves
-- this function.
---@param romFs RomFs
---@param opts table<string, unknown>|nil
---@return table<string, unknown>|nil, Errors.Error|string|nil
function ItemCatalogCompiler.compileAll(romFs, opts)
  opts = opts or {}
  local catalog, err = ItemCatalogCompiler.compileCatalog(romFs, opts)
  if not catalog then
    return nil, err
  end
  local icons, iconsErr = ItemPresentationCompiler.compileIcons(romFs)
  if not icons then
    return nil, iconsErr
  end
  local ok, result = pcall(function()
    must(ItemAssetSchema.assertIconManifest(icons.manifest))
    must(ItemAssetSchema.assertCatalogIcons(catalog, icons.manifest))
    local catalogHash = Hashing.hashLua(catalog)
    local iconPng = PngWriter.encode(icons.image.width, icons.image.height, icons.image.pixels)
    local iconHash = Hashing.sha1hex(iconPng)
    local index = {
      schema = ItemCache.INDEX_SCHEMA,
      version = catalog.version,
      catalogHash = catalogHash,
      iconHash = iconHash,
      catalog = ItemCache.catalogPath(),
      icons = ItemCache.iconImagePath(),
      iconManifest = ItemCache.iconManifestPath(),
    }
    must(ItemAssetSchema.assertIndex(index))
    local romSha1 = romFs:metadata().sha1
    local marker = ItemCache.marker(
      romSha1,
      Hashing.hashLua({
        catalog = catalogHash,
        icons = iconHash,
        iconManifest = Hashing.hashLua(icons.manifest),
      })
    )
    return {
      marker = marker,
      index = index,
      catalog = catalog,
      icons = icons.image,
      iconManifest = icons.manifest,
      iconPng = iconPng,
      provenance = {
        schema = "g4-item-provenance-v1",
        source = ItemSources.provenance,
        rom = { version = catalog.version.id, sha1 = romSha1 },
      },
    }
  end)
  if not ok then
    if Errors.is(result) then
      return nil, result
    end
    error(result, 0)
  end
  return result
end

return ItemCatalogCompiler
