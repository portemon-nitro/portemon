-- Item asset schema contract: one strict generated catalog plus the icon
-- manifest shape. A representative valid root passes; materially distinct
-- malformed shapes fail loudly. The boolean predicates mirror the raising
-- validators.

local Assert = require("tests.support.Assert")
local ItemFixture = require("libs.items.tests.item_fixture")

local T = {}

local function schema()
  return require("libs.assets.src.ItemAssetSchema")
end

local function validRoot()
  return ItemFixture.buildAssetRoot()
end

function T.valid_roots_pass_and_predicates_mirror()
  local ItemAssetSchema = schema()
  Assert.isTrue(ItemAssetSchema.assertCatalog(validRoot()))
  Assert.isTrue(ItemAssetSchema.isValidCatalog(validRoot()))
end

function T.catalogs_require_exact_item_identity_coverage()
  local ItemAssetSchema = schema()
  -- Dataless source identities carry an empty description: the schema
  -- accepts the empty string while still rejecting a missing field.
  local blank = validRoot()
  blank.items["ITEM_55"].description = ""
  Assert.isTrue(ItemAssetSchema.isValidCatalog(blank))
  local missing = validRoot()
  missing.items["ITEM_55"] = nil
  Assert.isFalse(ItemAssetSchema.isValidCatalog(missing))
  local duplicated = validRoot()
  duplicated.items["ITEM_17_AGAIN"] = {
    nativeId = 17,
    name = "Potion?",
    nameIndefinite = "a Potion?",
    namePlural = "Potions?",
    description = "duplicate",
    pocket = "medicine",
    preventToss = false,
    selectable = false,
    isBall = false,
    friendshipBoost = false,
    icon = "POTION",
  }
  Assert.isFalse(ItemAssetSchema.isValidCatalog(duplicated))
  local missingSection = validRoot()
  missingSection.items = nil
  Assert.isFalse(ItemAssetSchema.isValidCatalog(missingSection))
end

function T.catalogs_reject_malformed_item_records()
  local ItemAssetSchema = schema()
  local variants = {
    extra_field = { price = 200 },
    text_ball = { isBall = "yes" },
    negative_id = { nativeId = -1 },
    past_range_id = { nativeId = 537 },
    fractional_id = { nativeId = 4.5 },
    empty_name = { name = "" },
    unknown_pocket = { pocket = "sack" },
  }
  for name, patch in pairs(variants) do
    local root = validRoot()
    local record = root.items["ITEM_55"]
    for key, value in pairs(patch) do
      record[key] = value
    end
    Assert.isFalse(ItemAssetSchema.isValidCatalog(root), "malformed item record must be rejected: " .. name)
  end
  -- Nil assignments are not expressible as table patches, so the missing
  -- required fields are dropped explicitly.
  for _, key in ipairs({ "friendshipBoost", "icon" }) do
    local root = validRoot()
    root.items["ITEM_55"][key] = nil
    Assert.isFalse(ItemAssetSchema.isValidCatalog(root), "missing item field must be rejected: " .. key)
  end
end

function T.catalogs_reject_malformed_pocket_records()
  local ItemAssetSchema = schema()
  local badPocketKey = validRoot()
  badPocketKey.items["ITEM_55"].pocket = "sack"
  Assert.isFalse(ItemAssetSchema.isValidCatalog(badPocketKey))
  local badCapacity = validRoot()
  badCapacity.pockets.medicine.capacity = 41
  Assert.isFalse(ItemAssetSchema.isValidCatalog(badCapacity))
  local missingPocket = validRoot()
  missingPocket.pockets.mail = nil
  Assert.isFalse(ItemAssetSchema.isValidCatalog(missingPocket))
  local extraPocket = validRoot()
  extraPocket.pockets.sack = { nativeId = 8, capacity = 1, maxQuantity = 1, ordering = "manual" }
  Assert.isFalse(ItemAssetSchema.isValidCatalog(extraPocket))
  local missingNames = validRoot()
  missingNames.pocketNames = nil
  Assert.isFalse(ItemAssetSchema.isValidCatalog(missingNames))
end

function T.catalogs_reject_malformed_optional_tm_and_berry_data()
  local ItemAssetSchema = schema()
  local tmMissingMove = validRoot()
  tmMissingMove.items["TM01"].tmhmMoveNativeId = nil
  Assert.isFalse(ItemAssetSchema.isValidCatalog(tmMissingMove))
  local tmMoveOutOfRange = validRoot()
  tmMoveOutOfRange.items["TM01"].tmhmMoveNativeId = 468
  Assert.isFalse(ItemAssetSchema.isValidCatalog(tmMoveOutOfRange))
  local plainWithMove = validRoot()
  plainWithMove.items["POTION"].tmhmMoveNativeId = 33
  Assert.isFalse(ItemAssetSchema.isValidCatalog(plainWithMove))
  local berryMissingPlural = validRoot()
  berryMissingPlural.items["CHERI_BERRY"].berryNamePlural = nil
  Assert.isFalse(ItemAssetSchema.isValidCatalog(berryMissingPlural))
  local plainWithBerry = validRoot()
  plainWithBerry.items["POTION"].berryNameSingular = "Potion Berry"
  plainWithBerry.items["POTION"].berryNamePlural = "Potion Berries"
  Assert.isFalse(ItemAssetSchema.isValidCatalog(plainWithBerry))
end

function T.catalogs_reject_malformed_roots()
  local ItemAssetSchema = schema()
  local badSchema = validRoot()
  badSchema.schema = "g4-mon-catalog-v2"
  Assert.isFalse(ItemAssetSchema.isValidCatalog(badSchema))
  local extraKey = validRoot()
  extraKey.sprites = {}
  Assert.isFalse(ItemAssetSchema.isValidCatalog(extraKey))
  local badVersion = validRoot()
  badVersion.version = { id = "", language = "en" }
  Assert.isFalse(ItemAssetSchema.isValidCatalog(badVersion))
end

local function validManifest()
  return {
    schema = "g4-item-icons-v1",
    atlas = "assets/generated/item/icons.png",
    entries = {
      POTION = { x = 0, y = 0, width = 32, height = 32 },
      POKE_BALL = { x = 32, y = 0, width = 32, height = 32 },
    },
    representative = { "POTION" },
  }
end

function T.manifests_validate_rects_and_representatives()
  local ItemAssetSchema = schema()
  Assert.isTrue(ItemAssetSchema.assertIconManifest(validManifest()))
  Assert.isTrue(ItemAssetSchema.isValidIconManifest(validManifest()))
  local badRect = validManifest()
  badRect.entries.POTION.width = 0
  Assert.isFalse(ItemAssetSchema.isValidIconManifest(badRect))
  local dangling = validManifest()
  dangling.representative = { "MISSING_ICON" }
  Assert.isFalse(ItemAssetSchema.isValidIconManifest(dangling))
  local badSchema = validManifest()
  badSchema.schema = "g4-item-icons-v0"
  Assert.isFalse(ItemAssetSchema.isValidIconManifest(badSchema))
end

function T.catalog_icons_must_resolve_to_manifest_entries()
  local ItemAssetSchema = schema()
  local root = validRoot()
  local manifest = validManifest()
  manifest.entries = {
    NONE = { x = 0, y = 0, width = 32, height = 32 },
    POTION = { x = 0, y = 0, width = 32, height = 32 },
  }
  manifest.representative = { "NONE" }
  Assert.throws(function()
    ItemAssetSchema.assertCatalogIcons(root, manifest)
  end)
end

function T.catalogs_require_held_item_action_metadata()
  local ItemAssetSchema = schema()
  Assert.equal(ItemAssetSchema.CATALOG_SCHEMA, "g4-item-catalog-v4")
  Assert.isTrue(ItemAssetSchema.isValidCatalog(validRoot()))
  for _, key in ipairs({ "isHm", "canHold", "heldFormEffect" }) do
    local root = validRoot()
    root.items["ITEM_55"][key] = nil
    Assert.isFalse(ItemAssetSchema.isValidCatalog(root), "missing held-item metadata must be rejected: " .. key)
  end
  local badEffect = validRoot()
  badEffect.items["ITEM_55"].heldFormEffect = "miracle"
  Assert.isFalse(ItemAssetSchema.isValidCatalog(badEffect))
  local badHold = validRoot()
  badHold.items["ITEM_55"].canHold = "yes"
  Assert.isFalse(ItemAssetSchema.isValidCatalog(badHold))
  local oldSchema = validRoot()
  oldSchema.schema = "g4-item-catalog-v2"
  Assert.isFalse(ItemAssetSchema.isValidCatalog(oldSchema), "the v2 schema no longer validates")
end

function T.catalogs_accept_enriched_held_behavior()
  local ItemAssetSchema = schema()
  local enriched = validRoot()
  enriched.items["POTION"].heldBehavior = { key = "no_hold_effect", params = { nativeId = 17, holdEffect = 0 } }
  enriched.items["POKE_BALL"].heldBehavior = { key = "ball", params = { nativeId = 4 } }
  Assert.isTrue(ItemAssetSchema.isValidCatalog(enriched))
  Assert.isTrue(ItemAssetSchema.assertCatalog(enriched))
  Assert.isTrue(ItemAssetSchema.isValidCatalog(validRoot()), "records without held behavior stay valid")
end

function T.catalogs_reject_malformed_held_behavior()
  local ItemAssetSchema = schema()
  local cases = {
    empty_key = { key = "", params = {} },
    missing_params = { key = "ball" },
    non_scalar_param = { key = "ball", params = { nativeId = {} } },
  }
  for name, heldBehavior in pairs(cases) do
    local root = validRoot()
    root.items["POTION"].heldBehavior = heldBehavior
    Assert.isFalse(ItemAssetSchema.isValidCatalog(root), "malformed held behavior must be rejected: " .. name)
  end
end

function T.catalogs_accept_enriched_throw_facts()
  local ItemAssetSchema = schema()
  local enriched = validRoot()
  enriched.items["POTION"].fling = { effect = 0, power = 30 }
  enriched.items["POTION"].naturalGift = { power = 0, typeId = 31, type = nil }
  enriched.items["CHERI_BERRY"].fling = { effect = 1, power = 10 }
  enriched.items["CHERI_BERRY"].naturalGift = { power = 60, typeId = 10, type = "fire" }
  Assert.isTrue(ItemAssetSchema.isValidCatalog(enriched))
  Assert.isTrue(ItemAssetSchema.assertCatalog(enriched))
  Assert.isTrue(ItemAssetSchema.isValidCatalog(validRoot()), "records without throw facts stay valid")
end

function T.catalogs_reject_malformed_throw_facts()
  local ItemAssetSchema = schema()
  local flingCases = {
    missing_power = { effect = 0 },
    negative_power = { effect = 0, power = -1 },
    past_byte_power = { effect = 0, power = 256 },
    unknown_field = { effect = 0, power = 10, spin = 1 },
  }
  for name, fling in pairs(flingCases) do
    local root = validRoot()
    root.items["POTION"].fling = fling
    Assert.isFalse(ItemAssetSchema.isValidCatalog(root), "malformed fling facts must be rejected: " .. name)
  end
  local giftCases = {
    missing_type_bits = { power = 60, type = "fire" },
    past_bit_power = { power = 256, typeId = 10, type = "fire" },
    past_field_type_bits = { power = 60, typeId = 32, type = nil },
    unknown_type_key = { power = 60, typeId = 10, type = "inferno" },
  }
  for name, naturalGift in pairs(giftCases) do
    local root = validRoot()
    root.items["POTION"].naturalGift = naturalGift
    Assert.isFalse(ItemAssetSchema.isValidCatalog(root), "malformed natural-gift facts must be rejected: " .. name)
  end
end

function T.catalogs_require_party_use_metadata()
  local ItemAssetSchema = schema()
  Assert.isTrue(ItemAssetSchema.isValidCatalog(validRoot()))
  local missing = validRoot()
  missing.items["ITEM_55"].partyUse = nil
  Assert.isFalse(ItemAssetSchema.isValidCatalog(missing), "missing party-use metadata must be rejected")
  local unknownKind = validRoot()
  unknownKind.items["ITEM_55"].partyUse = { kind = "miracle" }
  Assert.isFalse(ItemAssetSchema.isValidCatalog(unknownKind), "an unknown effect kind must be rejected")
  local badAmount = validRoot()
  badAmount.items.POTION.partyUse = {
    kind = "medicine",
    cures = {
      sleep = false,
      poison = false,
      burn = false,
      freeze = false,
      paralysis = false,
    },
    restore = { kind = "fixed", amount = 0 },
    revive = "none",
    mood = 0,
  }
  Assert.isFalse(ItemAssetSchema.isValidCatalog(badAmount), "a zero restore amount must be rejected")
  local badDelta = validRoot()
  badDelta.items.POTION.partyUse = {
    kind = "ev",
    changes = { { stat = "hp", delta = 101 } },
    mood = 0,
  }
  Assert.isFalse(ItemAssetSchema.isValidCatalog(badDelta), "an out-of-range effort delta must be rejected")
  local zeroDelta = validRoot()
  zeroDelta.items.POTION.partyUse = {
    kind = "ev",
    changes = { { stat = "hp", delta = 0 } },
    mood = 0,
  }
  Assert.isFalse(ItemAssetSchema.isValidCatalog(zeroDelta), "a zero effort delta must be rejected")
  local partial = validRoot()
  partial.items.POTION.partyUse = { kind = "medicine" }
  Assert.isFalse(ItemAssetSchema.isValidCatalog(partial), "a partial effect record must be rejected")
  local badReason = validRoot()
  badReason.items.POTION.partyUse = { kind = "deferred", reason = "later" }
  Assert.isFalse(ItemAssetSchema.isValidCatalog(badReason), "an unknown deferral reason must be rejected")
end

function T.catalogs_accept_enriched_battle_use()
  local ItemAssetSchema = schema()
  local enriched = validRoot()
  enriched.items["POTION"].battleUse = {
    cures = { confusion = false, infatuation = false },
    guardSpec = false,
    stages = {
      attack = 1,
      defense = 0,
      specialAttack = 0,
      specialDefense = 0,
      speed = 0,
      accuracy = 0,
      critical = 0,
    },
  }
  enriched.items["SITRUS_BERRY"].battleUse = {
    cures = { confusion = true, infatuation = true },
    guardSpec = false,
    stages = {
      attack = 0,
      defense = 0,
      specialAttack = 0,
      specialDefense = 0,
      speed = 0,
      accuracy = 0,
      critical = 0,
    },
  }
  Assert.isTrue(ItemAssetSchema.isValidCatalog(enriched))
  Assert.isTrue(ItemAssetSchema.assertCatalog(enriched))
  Assert.isTrue(ItemAssetSchema.isValidCatalog(validRoot()), "records without battle use stay valid")
end

function T.catalogs_reject_malformed_battle_use()
  local ItemAssetSchema = schema()
  local function battleUseWith(patch)
    local record = {
      cures = { confusion = false, infatuation = false },
      guardSpec = false,
      stages = {
        attack = 1,
        defense = 0,
        specialAttack = 0,
        specialDefense = 0,
        speed = 0,
        accuracy = 0,
        critical = 0,
      },
    }
    for key, value in pairs(patch) do
      record[key] = value
    end
    return record
  end
  local cases = {
    unknown_field = battleUseWith({ spin = 1 }),
    non_boolean_cure = battleUseWith({ cures = { confusion = "yes", infatuation = false } }),
    unknown_cure = battleUseWith({ cures = { confusion = false, infatuation = false, sleep = true } }),
    non_boolean_guard = battleUseWith({ guardSpec = 1 }),
    missing_stage = (function()
      local record = battleUseWith({})
      record.stages.critical = nil
      return record
    end)(),
    unknown_stage = (function()
      local record = battleUseWith({})
      record.stages.evasion = 1
      return record
    end)(),
    negative_stage = (function()
      local record = battleUseWith({})
      record.stages.attack = -1
      return record
    end)(),
    past_nibble_stage = (function()
      local record = battleUseWith({})
      record.stages.attack = 16
      return record
    end)(),
    past_crit_bits = (function()
      local record = battleUseWith({})
      record.stages.critical = 4
      return record
    end)(),
  }
  local missingCures = battleUseWith({})
  missingCures.cures = nil
  cases.missing_cures = missingCures
  local missingStages = battleUseWith({})
  missingStages.stages = nil
  cases.missing_stages = missingStages
  local missingGuard = battleUseWith({ guardSpec = true })
  missingGuard.guardSpec = nil
  cases.missing_guard = missingGuard
  for name, battleUse in pairs(cases) do
    local root = validRoot()
    root.items["POTION"].battleUse = battleUse
    Assert.isFalse(ItemAssetSchema.isValidCatalog(root), "malformed battle use must be rejected: " .. name)
  end
end

return { tests = T }
