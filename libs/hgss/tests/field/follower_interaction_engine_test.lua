-- The follower interaction matcher consumes normalized data and live field/party owners.

local Assert = require("tests.support.Assert")
local Contract = require("libs.assets.src.DerivedAssetContract")
local FollowerInteractionCache = require("libs.assets.src.field.FollowerInteractionCache")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local ScriptRng = require("libs.hgss.src.script.ScriptRng")
local ENGINE_MODULE = "libs.hgss.src.field.FollowerInteractionEngine"
local loaded, FollowerInteractionEngine = pcall(require, ENGINE_MODULE)
if not loaded then
  local reason = tostring(FollowerInteractionEngine)
  assert(reason:find("module '" .. ENGINE_MODULE .. "' not found", 1, true), reason)
  FollowerInteractionEngine = nil
end

local T = {}

local CRITERIA = {
  "heldItemClass",
  "hpClass",
  "statusClass",
  "friendshipClass",
  "moodClass",
  "genderClass",
  "natureClass",
  "leafClass",
  "mapClass",
  "specialSpriteClass",
  "nearbyObjectClass",
  "hiddenItemClass",
  "weatherClass",
  "timeClass",
  "facingClass",
  "typeClass",
  "pokeathlonClass",
  "levelClass",
  "encounterClass",
  "mapId",
  "metatileBehaviorId",
}

local function criteria(value)
  local result = {}
  for _, key in ipairs(CRITERIA) do
    if key ~= "mapId" and key ~= "metatileBehaviorId" then
      result[key] = value
    end
  end
  return result
end

local function catalog(ruleSpecs, mapClassByMapId)
  local rulesByMapSection = {}
  for sectionId = 0, 235 do
    rulesByMapSection[sectionId] = {}
  end
  local programs = {}
  for _, spec in ipairs(ruleSpecs) do
    local rules = rulesByMapSection[spec.sectionId or 0]
    if rules == nil then
      rules = {}
      rulesByMapSection[spec.sectionId or 0] = rules
    end
    rules[#rules + 1] = {
      interactionId = spec.programId,
      percentage = spec.percentage,
      requiredFlagId = spec.requiredFlagId,
      criteria = criteria(0),
    }
    for key, value in pairs(spec.criteria or {}) do
      rules[#rules].criteria[key] = value
    end
    programs[spec.programId] = { steps = {}, friendshipDelta = 0, moodDelta = 0 }
  end
  local reactions = {}
  local fashionNames = {}
  for id = 1, 14 do
    local definition = "follower_reaction_" .. id
    reactions[id] = {
      definition = definition,
      resourceKey = FieldEffectAssetCache.definitionPath(definition),
    }
  end
  for id = 0, 99 do
    fashionNames[id] = { name = "Accessory", nameWithArticle = "an Accessory" }
  end
  local mapClasses = {}
  for mapId = 1, 496 do
    mapClasses[mapId] = 0
  end
  for mapId, class in pairs(mapClassByMapId or {}) do
    mapClasses[mapId] = class
  end
  return {
    schema = Contract.followerInteractions.schema,
    version = "soulsilver",
    rulesByMapSection = rulesByMapSection,
    programs = programs,
    motions = {},
    reactions = reactions,
    mapClassByMapId = mapClasses,
    locationNames = { [1] = "New Bark Town" },
    fashionNames = fashionNames,
  }
end

local function performance(base, minimum, maximum)
  local result = {}
  for _, key in ipairs({ "power", "skill", "speed", "jump", "stamina" }) do
    result[key] = { base = base, min = minimum, max = maximum }
  end
  return result
end

local function engine(ruleSpecs, formPerformance, options)
  options = options or {}
  Assert.notNil(
    FollowerInteractionEngine,
    "ordered follower selection is missing: no engine can evaluate normalized interaction rules"
  )
  local mon = {
    species = "EEVEE",
    form = 0,
    personality = 0,
    experience = 0,
    condition = { status = 0, currentHp = 20 },
    maxHp = 20,
    friendship = 100,
    mood = 0,
    shinyLeaves = 0,
    heldItem = nil,
    level = 1,
    nature = 0,
    gender = 0,
    type1 = 0,
    type2 = 0,
  }
  for key, value in pairs(options.mon or {}) do
    if key == "condition" then
      for conditionKey, conditionValue in pairs(value) do
        mon.condition[conditionKey] = conditionValue
      end
    else
      mon[key] = value
    end
  end
  local rng = ScriptRng.new(173)
  local world = {
    rng = rng,
    isFlagSet = function(_, flagId)
      return options.flags and options.flags[flagId] == true or false
    end,
  }
  local monCatalog = {
    species = function(_, species)
      Assert.equal(species, mon.species, "classifier fixture resolves its lead species")
      return { nativeId = options.speciesId or 133 }
    end,
    form = function()
      return { performance = formPerformance or performance(1, 1, 1) }
    end,
  }
  local mons = {
    leadAliveSlot = function()
      return 0
    end,
    partyMon = function()
      return mon
    end,
    catalog = function()
      return monCatalog
    end,
    partyMonDerived = function()
      return { level = mon.level, maxHp = mon.maxHp }
    end,
    monNature = function()
      return mon.personality % 25
    end,
    monGender = function()
      return mon.gender
    end,
    monTypes = function()
      return mon.type1, mon.type2
    end,
    monFriendship = function()
      return mon.friendship
    end,
    scriptMonLevel = function()
      return mon.level
    end,
  }
  local followerPosition = options.followerPosition or { fieldX = 0, fieldZ = 0 }
  local followerActor = options.followingActor
    or setmetatable({
      objectEventId = 0xFD,
      facing = options.followerFacing or "south",
      numericState = function(_)
        return {
          fieldX = followerPosition.fieldX,
          fieldZ = followerPosition.fieldZ,
          worldY = followerPosition.worldY,
          hasWorldPosition = followerPosition.worldY ~= nil and 1 or 0,
        }
      end,
      getSourceSurfaceId = function()
        return followerPosition.sourceSurfaceId
      end,
    }, {
      __index = function(_, key)
        if key == "cellKey" then
          return followerPosition.cellKey
        end
      end,
    })
  local fieldActors = {}
  for _, actor in ipairs(options.actors or {}) do
    fieldActors[#fieldActors + 1] = actor
  end
  fieldActors[#fieldActors + 1] = followerActor
  local actorManager = {
    actorsOf = function()
      return fieldActors
    end,
    getById = function(_, actorId)
      if actorId == "field:partner" then
        return followerActor
      end
      return nil
    end,
  }
  local followingMon = {
    partnerActorId = function()
      return "field:partner"
    end,
  }
  local data = catalog(ruleSpecs, options.mapClassByMapId)
  local testPlayer = options.player or { facing = "south", fieldX = 0, fieldZ = 0 }
  testPlayer.position = function(self)
    return { fieldX = self.fieldX, fieldZ = self.fieldZ }
  end
  local valid, validationError = FollowerInteractionCache.validateCatalog(data)
  Assert.isTrue(valid, validationError and validationError.message)
  local instance = FollowerInteractionEngine.new({
    catalog = data,
    mons = mons,
    items = {
      item = function()
        return options.item
      end,
    },
    fashionCase = options.fashionCase or {},
    world = world,
    actors = actorManager,
    followingMon = followingMon,
    runtimeMap = options.runtimeMap or {
      mapId = options.mapId == nil and 1 or options.mapId,
      mapSectionNativeId = options.mapSectionNativeId or 0,
      effectiveWeatherId = options.weatherId or 0,
      coordinateOrigin = { x = 0, z = 0 },
      collision = {
        getLocal = function(_, localX, localZ)
          if options.collisionQueries then
            options.collisionQueries[#options.collisionQueries + 1] = { x = localX, z = localZ }
          end
          return { behavior = options.metatileBehaviorId or 0 }
        end,
      },
      fieldData = { events = { objects = options.objects or {}, background = options.background or {} } },
    },
    player = testPlayer,
    clock = {
      nowLocal = function()
        return options.civilTime or { year = 2024, month = 1, day = 1, hour = 12, minute = 0, second = 0 }
      end,
    },
  })
  return instance, rng, data, mon
end

local function selectOne(mon, expectedCriteria, options)
  local engineOptions = {}
  for key, value in pairs(options or {}) do
    engineOptions[key] = value
  end
  engineOptions.mon = mon
  local subject = engine(
    { {
      programId = 1,
      percentage = 100,
      criteria = expectedCriteria,
    } },
    nil,
    engineOptions
  )
  return subject:select()
end

T["synthetic normalized interaction catalog satisfies the provider contract"] = function()
  local valid, validationError = FollowerInteractionCache.validateCatalog(catalog({
    {
      programId = 1,
      percentage = 100,
      criteria = { mapClass = 1, specialSpriteClass = 1, mapId = 1, metatileBehaviorId = 2 },
    },
  }, { [1] = 1 }))
  Assert.isTrue(valid, validationError and validationError.message)
end

T["earliest passing flattened row wins and stops later RNG draws"] = function()
  Assert.notNil(FollowerInteractionEngine, "earliest retail interaction row must be selectable")
  local subject, rng, data = engine({
    { programId = 1, percentage = 100 },
    { programId = 2, percentage = 100 },
    { programId = 3, percentage = 100 },
  })
  -- The source compiler flattens common/section/common rows into this ordered
  -- per-section sequence. The first two overlap the live context; observing
  -- the first program proves that the flattened precedence is retained.
  local laterRule = assert(data.rulesByMapSection[0][2])
  local laterRead = false
  laterRule.percentage = nil
  setmetatable(laterRule, {
    __index = function(_, key)
      if key == "percentage" then
        laterRead = true
        return 100
      end
    end,
  })
  local selected = subject:select()

  Assert.deepEqual(selected, { leadSlot = 0, programId = 1 })
  Assert.equal(rng:serialize().calls, 1, "a later matching row must not consume a percentage draw")
  Assert.isFalse(laterRead, "selection must not inspect the next flattened row after a match")
  local expectedRng = ScriptRng.new(173)
  expectedRng:chance(100, 100)
  Assert.deepEqual(rng:serialize(), expectedRng:serialize(), "selection persists exactly the reached RNG state")
end

T["partner effect anchor exposes the committed stacked surface"] = function()
  local position = { fieldX = 12, fieldZ = 8, worldY = 2.5, cellKey = "upper", sourceSurfaceId = 9 }
  local subject = engine({}, nil, {
    followerPosition = position,
  })

  local first = subject:partnerEffectAnchor()
  Assert.deepEqual(first, {
    fieldX = 12,
    fieldZ = 8,
    worldY = 2.5,
    cellKey = "upper",
    sourceSurfaceId = 9,
  })
  position.fieldX, position.fieldZ, position.worldY = 13, 9, 3.5
  position.cellKey, position.sourceSurfaceId = "lower", 10
  Assert.deepEqual(subject:partnerEffectAnchor(), {
    fieldX = 13,
    fieldZ = 9,
    worldY = 3.5,
    cellKey = "lower",
    sourceSurfaceId = 10,
  })
  Assert.equal(first.fieldX, 12, "an earlier anchor remains a snapshot")
end

T["each reached percentage row consumes one persisted script RNG draw"] = function()
  Assert.notNil(FollowerInteractionEngine, "percentage-gated retail rows must be selectable")
  local subject, rng = engine({
    { programId = 1, percentage = 0 },
    { programId = 2, percentage = 100 },
  })
  local selected = subject:select()

  Assert.deepEqual(selected, { leadSlot = 0, programId = 2 })
  Assert.equal(rng:serialize().calls, 2, "each reached percentage gate consumes exactly one draw")
  local expectedRng = ScriptRng.new(173)
  expectedRng:chance(0, 100)
  expectedRng:chance(100, 100)
  Assert.deepEqual(rng:serialize(), expectedRng:serialize(), "each passed gate advances the persisted state once")
end

T["Pokéathlon scoring preserves reachable threshold transitions and tie order"] = function()
  Assert.notNil(FollowerInteractionEngine, "Pokéathlon context classification must exist")
  local basePerformance = performance(1, 1, 1)
  local subject = engine({}, basePerformance)
  local classify = subject._pokeathlonClass
  Assert.equal(type(classify), "function", "Pokéathlon rules need their owned classifier")
  local runtimeOrderRecords = performance(1, 1, 1)
  runtimeOrderRecords.skill = { base = 3, min = 1, max = 5 }
  local runtimeOrderClass = engine({}, runtimeOrderRecords):_pokeathlonClass(
    { species = "EEVEE", form = 0, personality = 1 },
    { year = 2024, month = 1, day = 1 }
  )
  Assert.equal(
    runtimeOrderClass,
    1,
    "runtime-order discriminator expected Power class 1, got " .. tostring(runtimeOrderClass)
  )
  local vectors = {
    { raw = -40, personality = 4, day = 4, stat = "speed", other = { power = 1 }, expected = 1 },
    { raw = -38, personality = 86, day = 1, stat = "stamina", other = { power = 1 }, expected = 2 },
    { raw = -15, personality = 0, day = 1, stat = "speed", other = { power = 1 }, expected = 5 },
    { raw = -13, personality = 712, day = 1, stat = "jump", other = { power = 1 }, expected = 4 },
    { raw = 13, personality = 24, day = 1, stat = "jump", other = { power = 2 }, expected = 4 },
    { raw = 15, personality = 25, day = 1, stat = "power", other = { stamina = 3 }, expected = 1 },
    { raw = 38, personality = 4, day = 1, stat = "power", other = { stamina = 3 }, expected = 1 },
    { raw = 40, personality = 120, day = 1, stat = "jump", other = { stamina = 1 }, expected = 4 },
  }
  for _, vector in ipairs(vectors) do
    local records = performance(1, 1, 1)
    records[vector.stat] = { base = 3, min = 1, max = 5 }
    for stat, base in pairs(vector.other) do
      records[stat] = { base = base, min = base, max = base }
    end
    local classifier = engine({}, records)
    local mon = { species = "EEVEE", form = 0, personality = vector.personality }
    local actual = classifier:_pokeathlonClass(mon, { year = 2024, month = 1, day = vector.day })
    Assert.equal(
      actual,
      vector.expected,
      "Pokéathlon winner at raw score "
        .. vector.raw
        .. " for "
        .. vector.stat
        .. " on day "
        .. vector.day
        .. ": expected "
        .. vector.expected
        .. ", got "
        .. tostring(actual)
    )
  end

  local tied = performance(1, 1, 1)
  tied.stamina, tied.jump = { base = 5, min = 5, max = 5 }, { base = 5, min = 5, max = 5 }
  local tieClassifier = engine({}, tied)
  local tieClass = tieClassifier:_pokeathlonClass(
    { species = "EEVEE", form = 0, personality = 2 },
    { year = 2024, month = 1, day = 1 }
  )
  Assert.equal(tieClass, 2, "equal Stamina/Jump stars keep earlier follower-scan Stamina (class 2)")

  local classWinners = {
    { stat = "power", class = 1 },
    { stat = "stamina", class = 2 },
    { stat = "jump", class = 4 },
    { stat = "skill", class = 3 },
    { stat = "speed", class = 5 },
  }
  for _, vector in ipairs(classWinners) do
    local records = performance(1, 1, 1)
    records[vector.stat] = { base = 5, min = 5, max = 5 }
    Assert.equal(
      engine({}, records):_pokeathlonClass({ species = "EEVEE", form = 0, personality = 0 }, {
        year = 2024,
        month = 1,
        day = 1,
      }),
      vector.class,
      "winner class for " .. vector.stat
    )
  end
end

T["mon context classifiers preserve retail boundary buckets"] = function()
  local hpVectors = {
    { 100, 1 },
    { 75, 2 },
    { 74, 3 },
    { 50, 3 },
    { 49, 4 },
    { 25, 4 },
    { 24, 5 },
    { 0, 5 },
  }
  for _, vector in ipairs(hpVectors) do
    local subject = engine({}, nil, { mon = { condition = { currentHp = vector[1] }, maxHp = 100 } })
    Assert.equal(subject:_context(0).hpClass, vector[2], "HP class at " .. vector[1] .. "%")
  end

  local friendshipVectors = {
    { 255, 1 },
    { 200, 2 },
    { 199, 3 },
    { 150, 3 },
    { 149, 4 },
    { 90, 4 },
    { 89, 5 },
    { 60, 5 },
    { 59, 6 },
    { 30, 6 },
    { 29, 7 },
    { 1, 7 },
    { 0, 8 },
  }
  for _, vector in ipairs(friendshipVectors) do
    local subject = engine({}, nil, { mon = { friendship = vector[1] } })
    Assert.equal(subject:_context(0).friendshipClass, vector[2], "friendship class at " .. vector[1])
  end
  Assert.deepEqual(selectOne({ friendship = 90 }, { friendshipClass = 9 }), { leadSlot = 0, programId = 1 })
  Assert.equal(selectOne({ friendship = 89 }, { friendshipClass = 9 }), nil)
  Assert.deepEqual(selectOne({ friendship = 59 }, { friendshipClass = 10 }), { leadSlot = 0, programId = 1 })
  Assert.equal(selectOne({ friendship = 60 }, { friendshipClass = 10 }), nil)

  local moodVectors = {
    { 127, 1 },
    { 126, 2 },
    { 100, 2 },
    { 99, 3 },
    { 50, 3 },
    { 49, 4 },
    { 30, 4 },
    { 29, 5 },
    { 0, 5 },
    { -29, 5 },
    { -30, 6 },
    { -49, 6 },
    { -50, 7 },
    { -127, 8 },
  }
  for _, vector in ipairs(moodVectors) do
    local subject = engine({}, nil, { mon = { mood = vector[1] } })
    Assert.equal(subject:_context(0).moodClass, vector[2], "mood class at " .. vector[1])
  end
  Assert.deepEqual(selectOne({ mood = 0 }, { moodClass = 9 }), { leadSlot = 0, programId = 1 })
  Assert.equal(selectOne({ mood = -1 }, { moodClass = 9 }), nil)
  Assert.deepEqual(selectOne({ mood = -1 }, { moodClass = 10 }), { leadSlot = 0, programId = 1 })
  Assert.equal(selectOne({ mood = 0 }, { moodClass = 10 }), nil)

  for _, vector in ipairs({ { 0, 1 }, { 1, 2 }, { 2, 2 } }) do
    local subject = engine({}, nil, { mon = { gender = vector[1] } })
    Assert.equal(subject:_context(0).genderClass, vector[2], "gender " .. vector[1])
  end
  for _, vector in ipairs({ { "north", 3 }, { "south", 4 }, { "west", 2 }, { "east", 1 } }) do
    local subject = engine({}, nil, { followerFacing = vector[1] })
    Assert.equal(subject:_context(0).facingClass, vector[2], "follower facing " .. vector[1])
  end

  local statusVectors = {
    { 0, 1 },
    { 0x10, 2 },
    { 0x20, 3 },
    { 0x40, 4 },
    { 0x8, 5 },
    { 0x80, 5 },
    { 0x1, 8 },
    { 0x81, 5 },
  }
  for _, vector in ipairs(statusVectors) do
    local subject = engine({}, nil, { mon = { condition = { status = vector[1] } } })
    Assert.equal(subject:_context(0).statusClass, vector[2], "status condition " .. vector[1])
  end
  for _, status in ipairs({ 0x10, 0x20, 0x40, 0x8, 0x80, 0x1 }) do
    Assert.deepEqual(
      selectOne({ condition = { status = status } }, { statusClass = 7 }),
      { leadSlot = 0, programId = 1 },
      "status-any selector includes condition " .. status
    )
  end
  Assert.equal(
    selectOne({ condition = { status = 0 } }, { statusClass = 7 }),
    nil,
    "status-any selector excludes healthy"
  )

  local natureClasses = { 4, 5, 4, 4, 1, 4, 3, 2, 1, 2, 5, 6, 3, 1, 1, 3, 6, 3, 5, 6, 2, 2, 1, 3, 6 }
  for nature, expected in ipairs(natureClasses) do
    local subject = engine({}, nil, { mon = { personality = nature - 1 } })
    Assert.equal(subject:_context(0).natureClass, expected, "nature index " .. (nature - 1))
  end

  for _, vector in ipairs({
    { 0, 1 },
    { 1, 7 },
    { 2, 10 },
    { 3, 8 },
    { 4, 9 },
    { 5, 13 },
    { 6, 12 },
    { 7, 14 },
    { 8, 17 },
    { 10, 2 },
    { 11, 3 },
    { 12, 5 },
    { 13, 4 },
    { 14, 11 },
    { 15, 6 },
    { 16, 15 },
    { 17, 16 },
  }) do
    local subject = engine({ { programId = 1, percentage = 100, criteria = { typeClass = vector[2] } } }, nil, {
      mon = { type1 = vector[1], type2 = 9 },
    })
    Assert.deepEqual(subject:select(), { leadSlot = 0, programId = 1 }, "Gen4 type index " .. vector[1])
  end
  local eitherType = engine({ { programId = 1, percentage = 100, criteria = { typeClass = 13 } } }, nil, {
    mon = { type1 = 9, type2 = 5 },
  })
  Assert.deepEqual(eitherType:select(), { leadSlot = 0, programId = 1 }, "either mon type can satisfy the selector")
  Assert.equal(
    selectOne({ type1 = 9, type2 = 9 }, { typeClass = 1 }),
    nil,
    "unsupported type index does not match a supported type selector"
  )

  local mapClassCatalog = {
    { programId = 1, percentage = 100, criteria = { mapClass = 250 } },
    { programId = 2, percentage = 100, criteria = { mapClass = 7 } },
  }
  local sameMapEevee = engine(mapClassCatalog, nil, {
    mapId = 60,
    mapClassByMapId = { [60] = 18 },
    mon = { species = "EEVEE" },
  })
  local sameMapPikachu = engine(mapClassCatalog, nil, {
    mapId = 60,
    mapClassByMapId = { [60] = 18 },
    mon = { species = "PIKACHU" },
    speciesId = 25,
  })
  Assert.deepEqual(sameMapEevee:select(), { leadSlot = 0, programId = 1 })
  Assert.deepEqual(
    sameMapPikachu:select(),
    { leadSlot = 0, programId = 1 },
    "changing only follower species must preserve the map-owned class match"
  )
  local anotherMapClass = engine(mapClassCatalog, nil, {
    mapId = 61,
    mapClassByMapId = { [61] = 20 },
    mon = { species = "PIKACHU" },
    speciesId = 25,
  })
  Assert.equal(anotherMapClass:select(), nil, "changing map class must reject the 250 selector")
  local exactMapClass = engine({ {
    programId = 3,
    percentage = 100,
    criteria = { mapClass = 7 },
  } }, nil, {
    mapId = 62,
    mapClassByMapId = { [62] = 7 },
    mon = { species = "EEVEE" },
  })
  Assert.deepEqual(exactMapClass:select(), { leadSlot = 0, programId = 3 }, "exact map class remains supported")

  for _, vector in ipairs({
    { "items", 4 },
    { "medicine", 2 },
    { "balls", 1 },
    { "tmhm", 7 },
    { "berries", 6 },
    { "mail", 5 },
    { "battle_items", 3 },
  }) do
    local subject = engine({}, nil, {
      mon = { heldItem = "HELD_ITEM" },
      item = { pocket = vector[1] },
    })
    Assert.equal(subject:_context(0).heldItemClass, vector[2], "held-item pocket " .. vector[1])
  end
  local noHeldItem = engine({}, nil)
  Assert.equal(noHeldItem:_context(0).heldItemClass, 8, "no held item class")
  Assert.deepEqual(
    selectOne({ heldItem = "HELD_ITEM" }, { heldItemClass = 9 }, { item = { pocket = "medicine" } }),
    { leadSlot = 0, programId = 1 },
    "any-held selector matches a held item"
  )
  Assert.equal(selectOne({}, { heldItemClass = 9 }), nil, "any-held selector rejects no item")

  for selector = 1, 5 do
    Assert.deepEqual(
      selectOne({ shinyLeaves = 0 }, { leafClass = selector }),
      { leadSlot = 0, programId = 1 },
      "absent Shiny Leaf selector " .. selector
    )
    Assert.equal(
      selectOne({ shinyLeaves = 2 ^ (selector - 1) }, { leafClass = selector }),
      nil,
      "owned Shiny Leaf rejects absent selector " .. selector
    )
  end

  local mapSelection = engine({
    { programId = 1, percentage = 100, sectionId = 0, criteria = { mapId = 1 } },
    { programId = 2, percentage = 100, sectionId = 1, criteria = { mapId = 1 } },
    { programId = 3, percentage = 100, sectionId = 1, criteria = { mapId = 2 } },
  }, nil, { mapId = 1, mapSectionNativeId = 1 })
  Assert.deepEqual(
    mapSelection:select(),
    { leadSlot = 0, programId = 2 },
    "native map section selects its own rows and map ID matches exactly"
  )
  Assert.equal(selectOne({}, { mapId = 2 }, { mapId = 1 }), nil, "different exact map ID does not match")
  Assert.deepEqual(
    selectOne({}, { mapId = 1 }, { mapId = 1 }),
    { leadSlot = 0, programId = 1 },
    "map ID is an exact selector"
  )
  Assert.equal(selectOne({}, { mapId = 1 }, { mapId = 2 }), nil, "map ID does not match another map")

  for _, vector in ipairs({ { 0, 4 }, { 1, 4 }, { 47, 4 }, { 48, 6 }, { 52, 6 }, { 53, 5 } }) do
    local subject = engine({}, nil, { mon = { level = vector[1] } })
    Assert.equal(subject:_context(0).levelClass, vector[2], "level class at " .. vector[1])
  end
end

T["all retail walking-encounter behaviors classify the live follower tile"] = function()
  local encounterBehaviors = { 2, 3, 5, 8, 11, 16, 18, 21, 37, 42, 114, 119, 123, 166, 167 }
  local encounterSet = {}
  for _, behavior in ipairs(encounterBehaviors) do
    encounterSet[behavior] = true
    local queries = {}
    local subject = engine({}, nil, {
      metatileBehaviorId = behavior,
      followerPosition = { fieldX = 3, fieldZ = 5 },
      collisionQueries = queries,
    })
    local context = subject:_context(0)
    Assert.equal(context.metatileBehaviorId, behavior, "follower tile behavior " .. behavior)
    Assert.equal(context.encounterClass, 1, "walking encounter class for behavior " .. behavior)
    Assert.deepEqual(queries, { { x = 3, z = 5 } }, "classifier probes the live follower tile")
  end
  for _, behavior in ipairs({ 1, 4, 6, 9, 12, 17, 22, 36, 38, 41, 43, 113, 115, 118, 120, 122, 124, 165, 168 }) do
    Assert.isFalse(encounterSet[behavior] == true, "adjacent behavior " .. behavior .. " is not encounter flagged")
    Assert.equal(
      engine({}, nil, { metatileBehaviorId = behavior }):_context(0).encounterClass,
      2,
      "non-encounter behavior " .. behavior
    )
  end
end

T["time, weather, and hidden-item classifiers use live field values"] = function()
  Assert.notNil(FollowerInteractionEngine, "live field context classification must exist")
  local timeVectors = {
    { 0, 1 },
    { 3, 1 },
    { 4, 2 },
    { 9, 2 },
    { 10, 3 },
    { 16, 3 },
    { 17, 4 },
    { 19, 4 },
    { 20, 5 },
    { 23, 5 },
  }
  for _, vector in ipairs(timeVectors) do
    local subject = engine(
      {},
      nil,
      { civilTime = { year = 2024, month = 1, day = 1, hour = vector[1], minute = 0, second = 0 } }
    )
    Assert.equal(subject:_context(0).timeClass, vector[2], "time class at hour " .. vector[1])
  end

  for _, vector in ipairs({ { 0, 1 }, { 1, 3 }, { 2, 0 }, { 7, 0 } }) do
    local subject = engine({}, nil, { weatherId = vector[1] })
    Assert.equal(subject:_context(0).weatherClass, vector[2], "interaction weather class " .. vector[1])
  end

  Assert.deepEqual(
    selectOne({}, { encounterClass = 1 }, { metatileBehaviorId = 2 }),
    { leadSlot = 0, programId = 1 },
    "encounter selector matches encounter grass"
  )
  Assert.equal(
    selectOne({}, { encounterClass = 1 }, { metatileBehaviorId = 4 }),
    nil,
    "encounter selector rejects non-encounter behavior"
  )
  Assert.deepEqual(
    selectOne({}, { metatileBehaviorId = 2 }, { metatileBehaviorId = 2 }),
    { leadSlot = 0, programId = 1 },
    "nonzero metatile selector is exact"
  )
  Assert.equal(
    selectOne({}, { metatileBehaviorId = 2 }, { metatileBehaviorId = 4 }),
    nil,
    "nonmatching metatile selector rejects"
  )
  Assert.deepEqual(
    selectOne({}, {}, { metatileBehaviorId = 4 }),
    { leadSlot = 0, programId = 1 },
    "metatile behavior zero is absent from source-normalized criteria"
  )

  local subject = engine({}, nil, {
    background = {
      { type = 2, hiddenItemFlagId = 100 },
      { type = 2, hiddenItemFlagId = 101 },
      { type = 1, hiddenItemFlagId = 102 },
    },
    flags = { [100] = true },
  })
  Assert.equal(subject:_context(0).hiddenItemCount, 1, "only uncollected hidden-item events contribute")
  local fourItems = {
    { type = 2, hiddenItemFlagId = 200 },
    { type = 2, hiddenItemFlagId = 201 },
    { type = 2, hiddenItemFlagId = 202 },
    { type = 2, hiddenItemFlagId = 203 },
  }
  Assert.deepEqual(
    selectOne({}, { hiddenItemClass = 4 }, { background = fourItems }),
    { leadSlot = 0, programId = 1 },
    "hidden-item selector 4 means four or more"
  )
  Assert.equal(
    selectOne({}, { hiddenItemClass = 4 }, { background = { fourItems[1], fourItems[2], fourItems[3] } }),
    nil,
    "hidden-item selector 4 rejects three"
  )
end

T["nearby-object selection counts local actors and recognizes special sprites"] = function()
  local function actor(objectEventId, spriteId, fieldX, fieldZ)
    return {
      objectEventId = objectEventId,
      spriteId = spriteId,
      numericState = function()
        return { fieldX = fieldX, fieldZ = fieldZ }
      end,
    }
  end

  local localActor = actor(1, 1, 1, -1)
  local distantActor = actor(2, 1, 2, 0)
  local playerAndPartner = {
    actor(0xFD, 1, 0, 1),
    actor(0xFF, 1, 0, -1),
  }
  local localResult = selectOne({}, { nearbyObjectClass = 1 }, {
    player = { facing = "south", fieldX = 0, fieldZ = 0 },
    actors = { localActor, distantActor, playerAndPartner[1], playerAndPartner[2] },
  })
  Assert.deepEqual(localResult, { leadSlot = 0, programId = 1 }, "one local object excludes distant and special IDs")

  local fiveActors = {}
  for objectEventId = 1, 5 do
    fiveActors[#fiveActors + 1] = actor(objectEventId, 1, (objectEventId % 3) - 1, (objectEventId % 2) - 1)
  end
  Assert.deepEqual(
    selectOne({}, { nearbyObjectClass = 5 }, {
      player = { facing = "south", fieldX = 0, fieldZ = 0 },
      actors = fiveActors,
    }),
    { leadSlot = 0, programId = 1 },
    "nearby-object selector 5 means at least five"
  )
  Assert.equal(
    selectOne({}, { nearbyObjectClass = 5 }, {
      player = { facing = "south", fieldX = 0, fieldZ = 0 },
      actors = { localActor },
    }),
    nil,
    "nearby-object selector 5 rejects fewer than five"
  )

  for selector = 1, 3 do
    for _, spriteId in ipairs({ 0x54, 0x55, 0x56 }) do
      Assert.equal(
        selectOne({}, { specialSpriteClass = selector }, { actors = { actor(1, spriteId, 0, 0) } }),
        nil,
        "nonzero special selector " .. selector .. " rejects sprite " .. spriteId
      )
    end
    Assert.equal(
      selectOne({}, { specialSpriteClass = selector }),
      nil,
      "nonzero special selector " .. selector .. " rejects without a matching live sprite"
    )
  end
  Assert.deepEqual(selectOne({}, { specialSpriteClass = 0 }), { leadSlot = 0, programId = 1 })
  for _, spriteId in ipairs({ 0x54, 0x55, 0x56 }) do
    Assert.equal(
      selectOne({}, { nearbyObjectClass = 1 }, { actors = { actor(1, spriteId, 0, 0) } }),
      nil,
      "special sprite " .. spriteId .. " does not count as an ordinary nearby object"
    )
  end
end

return { tests = T }
