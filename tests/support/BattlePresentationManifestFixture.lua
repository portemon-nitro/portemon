-- Synthetic schema-valid battle-presentation manifest shared by asset tests.

---@return table menu descriptor with one staged screen
local function menuSection()
  return {
    image = "assets/generated/battle/menu-command-1.png",
    screens = {
      {
        image = "assets/generated/battle/menu-command-1.png",
        width = 256,
        height = 256,
        tilemapKey = "menu/tilemap/synthetic",
        template = 1,
        priority = 2,
      },
    },
  }
end

---@return table sprite descriptor with one cell and one frame
local function spriteSection(image)
  return {
    image = image,
    cells = {
      {
        objs = {
          {
            x = 0,
            y = 0,
            tile = 0,
            flipH = false,
            flipV = false,
            palette = 0,
            shape = 0,
            size = 1,
            width = 16,
            height = 16,
            affine = false,
            disabled = false,
            objMode = "normal",
            mosaic = false,
            colorMode = "16-color",
            priority = 0,
          },
        },
      },
    },
    animation = { playMode = "forward_loop", loopStartFrameIdx = 0, frames = { { cell = 0, duration = 4 } } },
    palette = { colors = { { r = 0, g = 0, b = 0 } } },
  }
end

---@return table shared per-type terrain bake metadata without staged pixels
local function terrainSection()
  local sprite = spriteSection("assets/generated/battle/terrain-type0.png")
  return { cells = sprite.cells, animation = sprite.animation }
end

local makeIntroMusic

local function scriptMessageProgramContext()
  return {
    program = "battle-script",
    context = "battle-message",
    delivery = "message-scope-local",
    record = {
      input = "messageRecordReference",
      bank = "message-bank/script-controller",
      selection = "link-time-record-reference",
    },
    placeholders = {
      tagInput = "messageTagSymbol",
      parametersInput = "tagTypedParameters",
      schemaCatalog = "tagSchemas",
      contextCatalog = "tagInputs",
      placeholderCatalog = "placeholders",
      bufferCatalog = "templateInputs",
      expansionRoute = "battle/message-template",
    },
  }
end

---@return table valid staged global manifest
local function manifest()
  local fallbackRoutes = {}
  for _, terrain in ipairs({ "plain", "water", "cave" }) do
    for _, timeOfDay in ipairs({ "day", "late" }) do
      for _, battleKind in ipairs({ "wild", "trainer" }) do
        fallbackRoutes[#fallbackRoutes + 1] = {
          route = "trainer/red",
          terrain = terrain,
          timeOfDay = timeOfDay,
          battleKind = battleKind,
        }
      end
    end
  end
  local old = {
    schema = "g4-battle-presentation-v2",
    version = { id = "soulsilver", language = "en" },
    scenes = {
      { key = "general/grass/day", background = "general", terrain = "grass", time = "day" },
    },
    images = {
      ["assets/generated/battle/menu-command-1.png"] = { width = 256, height = 256 },
      ["assets/generated/battle/menu-frontier-layout.png"] = { width = 256, height = 256 },
      ["assets/generated/battle/menu-vs-recorder-layout.png"] = { width = 256, height = 256 },
      ["assets/generated/battle/lower-chars.png"] = { width = 3072, height = 8 },
      ["assets/generated/battle/hud-player-chars.png"] = { width = 1024, height = 8 },
      ["assets/generated/battle/hud-enemy-chars.png"] = { width = 1024, height = 8 },
      ["assets/generated/battle/hud-doubles-player-left-chars.png"] = { width = 1024, height = 8 },
      ["assets/generated/battle/hud-doubles-player-right-chars.png"] = { width = 1024, height = 8 },
      ["assets/generated/battle/hud-doubles-enemy-left-chars.png"] = { width = 1024, height = 8 },
      ["assets/generated/battle/hud-doubles-enemy-right-chars.png"] = { width = 1024, height = 8 },
      ["assets/generated/battle/arrow-chars.png"] = { width = 208, height = 8 },
      ["assets/generated/battle/gauges-0-chars.png"] = { width = 128, height = 8 },
      ["assets/generated/battle/gauges-1-chars.png"] = { width = 512, height = 8 },
    },
    command = menuSection(),
    moves = menuSection(),
    target = menuSection(),
    twoOption = menuSection(),
    lower = {
      image = "assets/generated/battle/lower-chars.png",
      palette = { colors = { { r = 1, g = 2, b = 3 } } },
      variants = {
        general = {
          base = { colors = { { r = 1, g = 2, b = 3 } } },
          touch = { colors = { { r = 4, g = 5, b = 6 } } },
        },
      },
    },
    playerHud = spriteSection("assets/generated/battle/hud-player-chars.png"),
    enemyHud = spriteSection("assets/generated/battle/hud-enemy-chars.png"),
    doublesHud = {
      playerLeft = spriteSection("assets/generated/battle/hud-doubles-player-left-chars.png"),
      playerRight = spriteSection("assets/generated/battle/hud-doubles-player-right-chars.png"),
      enemyLeft = spriteSection("assets/generated/battle/hud-doubles-enemy-left-chars.png"),
      enemyRight = spriteSection("assets/generated/battle/hud-doubles-enemy-right-chars.png"),
    },
    arrow = spriteSection("assets/generated/battle/arrow-chars.png"),
    partyGauges = {
      spriteSection("assets/generated/battle/gauges-0-chars.png"),
      spriteSection("assets/generated/battle/gauges-1-chars.png"),
    },
    terrain = {
      type0 = terrainSection(),
      type1 = terrainSection(),
    },
    textRoles = {
      narration = { font = "data/generated/field/font/font-0.lua" },
      trainerNarration = { font = "data/generated/field/font/font-0.lua" },
      hud = { font = "data/generated/field/font/font-0.lua" },
      menu = { font = "data/generated/field/font/font-4.lua" },
      bugContest = { font = "data/generated/field/font/font-0.lua" },
      recorderFeedback = { font = "data/generated/field/font/font-0.lua" },
    },
    audioRoles = {
      wild = "SEQ_GS_VS_NORAPOKE",
      trainer = "SEQ_GS_VS_TRAINER",
      rival = "SEQ_GS_VS_RIVAL",
      select = "SEQ_SE_DP_SELECT",
      gymLeader = "SEQ_GS_VS_GYMREADER",
      rocket = "SEQ_GS_VS_ROCKET",
      suicune = "SEQ_GS_VS_SUICUNE",
      entei = "SEQ_GS_VS_ENTEI",
      raikou = "SEQ_GS_VS_RAIKOU",
      champion = "SEQ_GS_VS_CHAMP",
      kantoWild = "SEQ_GS_VS_NORAPOKE_KANTO",
      kantoTrainer = "SEQ_GS_VS_TRAINER_KANTO",
      kantoGymLeader = "SEQ_GS_VS_GYMREADER_KANTO",
      cries = "species",
      introMusic = makeIntroMusic(),
    },
    pictureAttributes = {
      ["pokemon/CHIKORITA/form-0/male/back"] = {
        height = 0,
        animation = {
          steps = {
            { next = 0, duration = 1, xOffset = -1, auxiliary = 0 },
            { next = -1, duration = 0, xOffset = 0, auxiliary = 0 },
            { next = 0, duration = 0, xOffset = 0, auxiliary = 0 },
            { next = 0, duration = 0, xOffset = 0, auxiliary = 0 },
            { next = 0, duration = 0, xOffset = 0, auxiliary = 0 },
            { next = 0, duration = 0, xOffset = 0, auxiliary = 0 },
            { next = 0, duration = 0, xOffset = 0, auxiliary = 0 },
            { next = 0, duration = 0, xOffset = 0, auxiliary = 0 },
            { next = 0, duration = 0, xOffset = 0, auxiliary = 0 },
            { next = 0, duration = 0, xOffset = 0, auxiliary = 0 },
          },
        },
      },
    },
    programs = {
      ["synthetic-effect-probe"] = {
        entry = "main",
        taskKinds = { "synthetic-particle" },
        dependencies = { "trainer-message-index/pairs" },
        requiredContext = { actors = { type = "battle-actors" } },
      },
    },
    resources = {
      ["synthetic-transition-palette"] = {
        kind = "palette",
        contentIdentity = string.rep("a", 40),
        format = "nitro-palette-rgb888-v1",
        geometry = { colorCount = 16 },
        path = "data/generated/battle/resources/transition/synthetic/palette.lua",
      },
      ["menu/tilemap/synthetic"] = {
        kind = "map",
        contentIdentity = string.rep("b", 40),
        format = "nitro-bg-map-v1",
        geometry = { width = 256, height = 256, entryCount = 1024 },
        path = "data/generated/battle/resources/menu/tilemap/synthetic.lua",
      },
      ["menu/layout/frontier/character"] = {
        kind = "texture",
        contentIdentity = string.rep("c", 40),
        format = "nitro-char-8bpp-v1",
        geometry = { depth = 4, tileCount = 1024 },
        path = "data/generated/battle/resources/menu/layout/frontier/character.lua",
      },
      ["menu/layout/frontier/palette"] = {
        kind = "palette",
        contentIdentity = string.rep("d", 40),
        format = "nitro-palette-rgb888-v1",
        geometry = { colorCount = 256 },
        path = "data/generated/battle/resources/menu/layout/frontier/palette.lua",
      },
      ["menu/layout/frontier/tilemap"] = {
        kind = "map",
        contentIdentity = string.rep("e", 40),
        format = "nitro-bg-map-v1",
        geometry = { width = 256, height = 256, entryCount = 1024 },
        path = "data/generated/battle/resources/menu/layout/frontier/tilemap.lua",
      },
      ["menu/layout/frontier/touch-palette"] = {
        kind = "palette",
        contentIdentity = string.rep("f", 40),
        format = "nitro-palette-rgb888-v1",
        geometry = { colorCount = 256 },
        path = "data/generated/battle/resources/menu/layout/frontier/touch-palette.lua",
      },
      ["menu/layout/bug-contest/character"] = {
        kind = "texture",
        contentIdentity = string.rep("1", 40),
        format = "nitro-char-4bpp-v1",
        geometry = { depth = 3, tileCount = 256 },
        path = "data/generated/battle/resources/menu/layout/bug-contest/character.lua",
      },
      ["menu/layout/bug-contest/palette"] = {
        kind = "palette",
        contentIdentity = string.rep("2", 40),
        format = "nitro-palette-rgb888-v1",
        geometry = { colorCount = 256 },
        path = "data/generated/battle/resources/menu/layout/bug-contest/palette.lua",
      },
      ["menu/layout/bug-contest/cell"] = {
        kind = "cell",
        contentIdentity = string.rep("3", 40),
        format = "nitro-obj-cells-v1",
        geometry = {
          cellCount = 2,
          bounds = { { x = -8, y = -8, width = 16, height = 16 }, { x = 0, y = 0, width = 16, height = 16 } },
        },
        path = "data/generated/battle/resources/menu/layout/bug-contest/cell.lua",
      },
      ["menu/layout/bug-contest/animation"] = {
        kind = "animation",
        contentIdentity = string.rep("4", 40),
        format = "nitro-obj-animation-v1",
        geometry = { animationCount = 2, frameCount = 2, durationUnit = "native-frame" },
        path = "data/generated/battle/resources/menu/layout/bug-contest/animation.lua",
      },
      ["menu/layout/vs-recorder/tilemap"] = {
        kind = "map",
        contentIdentity = string.rep("f", 40),
        format = "nitro-bg-map-v1",
        geometry = { width = 256, height = 256, entryCount = 1024 },
        path = "data/generated/battle/resources/menu/layout/vs-recorder/tilemap.lua",
      },
      ["transition/particle/synthetic"] = {
        kind = "particle",
        contentIdentity = string.rep("5", 40),
        format = "nitro-spl-aps-v1",
        geometry = { emitterCount = 1, resourceCount = 2 },
        path = "data/generated/battle/resources/transition/particle/synthetic.lua",
      },
      ["message-bank/script-controller"] = {
        kind = "message",
        contentIdentity = string.rep("6", 40),
        format = "hgss-message-bank-tokens-v1",
        geometry = { recordCount = 1200, tokenCount = 2400 },
        path = "data/generated/battle/resources/message/script-controller.lua",
      },
      ["trainer-message-index/offsets"] = {
        kind = "message",
        contentIdentity = string.rep("7", 40),
        format = "hgss-trainer-message-offsets-v1",
        geometry = { recordCount = 2 },
        path = "data/generated/battle/resources/message/trainer-index-offsets.lua",
      },
      ["trainer-message-index/pairs"] = {
        kind = "message",
        contentIdentity = string.rep("8", 40),
        format = "hgss-trainer-message-pairs-v1",
        geometry = { recordCount = 2 },
        path = "data/generated/battle/resources/message/trainer-index-pairs.lua",
      },
    },
    coverage = {
      ["synthetic-effect-probe"] = {
        kind = "animation-program",
        program = "synthetic-effect-probe",
        closureIdentity = string.rep("a", 40),
        resources = { "trainer-message-index/pairs" },
        operations = { "wait-ticks" },
      },
      command = {
        kind = "menu-route",
        route = "command",
        closureIdentity = string.rep("c", 40),
        resources = {},
        operations = { "menu-route" },
        messageEntries = {},
        messageRoutes = {},
        fontRoles = { "menu" },
        assetRoles = {},
        assetBindings = {},
        requiredContext = { "main" },
      },
      ["battle/script-message"] = {
        kind = "message-route",
        route = "battle/script-message",
        closureIdentity = string.rep("d", 40),
        resources = { "message-bank/script-controller" },
        operations = { "message-route" },
        messageRoutes = { "battle/message-template" },
        programContext = scriptMessageProgramContext(),
      },
      ["battle/message-template"] = {
        kind = "message-route",
        route = "battle/message-template",
        closureIdentity = string.rep("9", 40),
        resources = { "message-bank/script-controller" },
        operations = { "message-route" },
      },
      ["battle/trainer-pair-speech"] = {
        kind = "message-route",
        route = "battle/trainer-pair-speech",
        closureIdentity = string.rep("e", 40),
        resources = { "message-bank/script-controller", "trainer-message-index/offsets", "trainer-message-index/pairs" },
        operations = { "message-route" },
      },
      ["transition/trainer/red"] = {
        kind = "transition-route",
        route = "trainer/red",
        closureIdentity = string.rep("b", 40),
        resources = { "menu/layout/bug-contest/palette" },
        operations = { "red-trainer-transition" },
      },
    },
  }
  return {
    schema = old.schema,
    version = old.version,
    catalogIdentity = "synthetic-catalog",
    scenes = old.scenes,
    layouts = { scene = { canvas = { width = 512, height = 256 } } },
    hud = {
      player = old.playerHud,
      enemy = old.enemyHud,
      doubles = old.doublesHud,
      arrow = old.arrow,
      partyGauges = old.partyGauges,
      terrain = old.terrain,
      roles = { health = "player-and-enemy" },
      selectors = { single = "player", double = "doubles" },
    },
    pictures = {
      attributes = old.pictureAttributes,
      selectors = { exemplar = "pokemon/CHIKORITA/form-0/male/back" },
    },
    menus = {
      images = old.images,
      layouts = {
        frontier = {
          image = "assets/generated/battle/menu-frontier-layout.png",
          character = "menu/layout/frontier/character",
          palette = "menu/layout/frontier/palette",
          tilemap = "menu/layout/frontier/tilemap",
          touchPalette = "menu/layout/frontier/touch-palette",
        },
        vsRecorder = {
          image = "assets/generated/battle/menu-vs-recorder-layout.png",
          tilemap = "menu/layout/vs-recorder/tilemap",
        },
        bugContest = {
          character = "menu/layout/bug-contest/character",
          palette = "menu/layout/bug-contest/palette",
          cell = "menu/layout/bug-contest/cell",
          animation = "menu/layout/bug-contest/animation",
          sprites = {
            sportBall = { x = 208, y = 16, palette = 5, animation = 0 },
            bugNet = { x = 88, y = 8, palette = 4, animation = 1 },
          },
        },
      },
      routes = {
        command = {
          screenGroup = "command",
          textSet = "main",
          messageEntries = {},
          messageRoutes = {},
          fontRoles = { "menu" },
          assetRoles = {},
          assetBindings = {},
          requiredContext = { "main" },
          resources = {},
        },
      },
      command = old.command,
      moves = old.moves,
      target = old.target,
      twoOption = old.twoOption,
      lower = old.lower,
      roles = { command = "command" },
      selectors = { command = "command" },
      runtimeContexts = {
        bugContest = { inputs = { "caughtPokemonSpecies" }, assetRoles = { "pokemonIcon" } },
        targetSelection = { inputs = { "selectedTarget" }, assetRoles = { "pokemonIcon" } },
        moveSelection = { inputs = { "moveIds" }, assetRoles = { "moveTypeIcon" } },
        frontierLayout = { inputs = { "frontierBattle" }, assetRoles = { "frontierMenuLayout" } },
      },
      contexts = {
        main = {
          inputs = {
            mode = { type = "enum", values = { "standard", "safari", "pal-park", "bug-contest" } },
            cancelRun = { type = "boolean" },
            frontier = { type = "boolean" },
          },
          modes = { "standard", "safari", "pal-park", "bug-contest" },
        },
        bugContest = {
          caughtPokemon = {
            optional = true,
            fields = {
              species = "species",
              form = "form",
              gender = { type = "enum", values = { "male", "female", "genderless" } },
              level = "integer",
            },
            absentSpecies = "species/none",
          },
          remainingSafariBalls = "integer",
          sprites = "bugContest",
        },
        frontier = { input = "frontierBattle", overrides = "frontier" },
        moveSelection = {
          slotCount = 4,
          slots = {
            move = "move",
            currentPP = "integer",
            maximumPP = "integer",
            derived = { moveName = "move-name", moveType = "move-type", typeIcon = "move-type-icon" },
            emptyMove = "move/none",
          },
        },
        targetSelection = {
          slotCount = 4,
          order = "targetOrder",
          hitMask = "targetHitMask",
          visibility = { candidateFlag = "hide", requiredValue = true, hitRequired = true },
          candidate = {
            battler = "battler",
            gender = "gender",
            selectedPartyMon = "party-index",
            hp = "integer",
            maximumHP = "integer",
            status = "battle-status",
            nickname = "box-mon-nickname",
            species = "species",
            form = "form",
          },
          iconAssetRoles = { "pokemonIcon", "battleCondition" },
        },
        vsRecorder = {
          inputs = { playbackStatus = { type = "enum", values = { "paused", "corrupted" } } },
          screenRole = "vsRecorder",
          stopMessage = "label/recorder-stop",
          feedbackRoute = "menu/vs-recorder-feedback",
        },
      },
      modeRules = {
        standard = {
          labels = { fight = "label/fight", bag = "label/bag", pokemon = "label/pokemon" },
          dynamicFields = {},
        },
        safari = {
          labels = { fight = "label/safari-ball", bag = "label/safari-bait", pokemon = "label/safari-mud" },
          dynamicFields = {},
        },
        ["pal-park"] = {
          labels = { fight = "label/pal-park-ball", bag = "label/safari-bait", pokemon = "label/safari-mud" },
          dynamicFields = {},
        },
        ["bug-contest"] = {
          labels = { fight = "label/fight", bag = "label/bug-contest-ball", pokemon = "label/pokemon" },
          dynamicFields = { "caughtPokemonGender", "caughtPokemonLevel", "remainingBalls" },
        },
      },
      runLabelSelector = { cancel = "label/cancel", ordinary = "label/run" },
    },
    messages = {
      roles = old.textRoles,
      banks = {
        scriptController = "message-bank/script-controller",
        frontierTrainerProfileZero = "message-bank/script-controller",
        frontierTrainerProfileFallback = "message-bank/script-controller",
        trainerPairLookup = "message-bank/script-controller",
        tutorialAuthor = "message-bank/script-controller",
      },
      dynamicRoutes = {
        captureShake = {
          bank = "message-bank/script-controller",
          input = "captureShakeCount",
          firstRecord = "battle/capture-shakes/0",
          minimum = 0,
          maximum = 4,
          recordCount = 5,
        },
        metBillPCTransfer = {
          banks = { "message-bank/script-controller" },
          inputs = { "metBill", "pcHasSpace" },
          cases = {
            { key = "battle/pc-transfer/has-space/someone", metBill = false, pcHasSpace = true },
            { key = "battle/pc-transfer/has-space/bill", metBill = true, pcHasSpace = true },
            { key = "battle/pc-transfer/box-full/someone", metBill = false, pcHasSpace = false },
            { key = "battle/pc-transfer/box-full/bill", metBill = true, pcHasSpace = false },
          },
        },
        frontierTrainerSpeech = {
          banks = { "message-bank/script-controller", "message-bank/script-controller" },
          inputs = { "trainerIndex", "outcome", "playerProfiles" },
          profilePredicate = "anyPlayerProfileVersionZero",
          recordFormula = { trainerIndexMultiplier = 3, winOffset = 1, lossOffset = 2 },
        },
        trainerPairSpeech = {
          bank = "message-bank/script-controller",
          inputs = { "trainerIndex", "trainerMessageKind" },
          selection = {
            lookup = "trainer-message-index",
            offsetsResource = "trainer-message-index/offsets",
            pairsResource = "trainer-message-index/pairs",
            offsetSelection = {
              input = "trainerIndex",
              elementStrideBytes = 2,
              valueWidthBytes = 2,
              result = "pair-record-byte-offset",
            },
            pairSelection = {
              inputs = { "trainerIndex", "trainerMessageKind" },
              recordStrideBytes = 4,
              match = "trainer-and-message-kind",
              result = "messageRecordReference",
            },
          },
        },
        tutorialAuthor = {
          bank = "message-bank/script-controller",
          input = "playerGender",
          variants = {
            malePlayer = "tutorial/author/male-player",
            femalePlayer = "tutorial/author/female-player",
          },
        },
      },
      placeholderBanks = {
        species = "message-bank/script-controller",
        move = "message-bank/script-controller",
      },
      sourceRoutes = {
        ["battle/script-message"] = {
          banks = { "message-bank/script-controller" },
          inputs = { "messageRecordReference", "messageTagSymbol", "tagTypedParameters" },
          recordSelection = "literal-at-script-callsite",
          placeholderPlan = "battleMessageTags",
          programContext = scriptMessageProgramContext(),
        },
        ["battle/message-template"] = {
          banks = { "message-bank/script-controller" },
          inputs = { "messageRecord", "battleMessageTag", "tagParameters" },
          bufferPlan = "tagSelectedBuffers",
        },
        ["battle/trainer-pair-speech"] = {
          banks = { "message-bank/script-controller" },
          inputs = { "trainerIndex", "trainerMessageKind" },
          recordSelection = "matching-trainer-and-message-kind",
          resources = { "trainer-message-index/offsets", "trainer-message-index/pairs" },
        },
      },
      placeholders = {
        species = { bank = "message-bank/script-controller", input = "speciesId" },
        move = { bank = "message-bank/script-controller", input = "moveId" },
      },
      tagSchemas = { nickname = { "nickname" }, ["nickname-move"] = { "nickname", "move" } },
      tagInputs = {
        nickname = { input = "battlerCategory", output = "battlerAndPartySlot" },
        move = { input = "moveSelector", output = "moveMessageRecord" },
      },
      templateInputs = { nickname = { input = "battlerAndPartySlot", dependency = "partyBoxMon" } },
      templateExpansion = { input = "tagSelectedBuffers" },
      entries = {
        ["battle/capture-shakes/0"] = { tokens = {} },
        ["battle/capture-shakes/1"] = { tokens = {} },
        ["battle/capture-shakes/2"] = { tokens = {} },
        ["battle/capture-shakes/3"] = { tokens = {} },
        ["battle/capture-shakes/4"] = { tokens = {} },
        ["battle/pc-transfer/has-space/someone"] = { tokens = {} },
        ["battle/pc-transfer/has-space/bill"] = { tokens = {} },
        ["battle/pc-transfer/box-full/someone"] = { tokens = {} },
        ["battle/pc-transfer/box-full/bill"] = { tokens = {} },
        ["label/fight"] = { tokens = {} },
        ["label/bag"] = { tokens = {} },
        ["label/pokemon"] = { tokens = {} },
        ["label/safari-ball"] = { tokens = {} },
        ["label/safari-bait"] = { tokens = {} },
        ["label/safari-mud"] = { tokens = {} },
        ["label/pal-park-ball"] = { tokens = {} },
        ["label/bug-contest-ball"] = { tokens = {} },
        ["label/cancel"] = { tokens = {} },
        ["label/run"] = { tokens = {} },
        ["label/recorder-stop"] = { tokens = {} },
        ["template/bug-contest-level"] = { tokens = {} },
        ["template/bug-contest-remaining-balls"] = { tokens = {} },
        ["template/mon-male-level"] = { tokens = {} },
        ["template/mon-female-level"] = { tokens = {} },
        ["template/mon-neutral-level"] = { tokens = {} },
        ["prompt/give-up"] = { tokens = {} },
        ["prompt/keep-battling"] = { tokens = {} },
        ["status/recorder-0"] = { tokens = {} },
        ["status/recorder-1"] = { tokens = {} },
        ["status/recorder-2"] = { tokens = {} },
        ["status/recorder-3"] = { tokens = {} },
        ["status/recorder-4"] = { tokens = {} },
        ["status/recorder-5"] = { tokens = {} },
        ["label/bug-contest-gender-male"] = { tokens = {} },
        ["label/bug-contest-gender-female"] = { tokens = {} },
        ["tutorial/author/male-player"] = { tokens = {} },
        ["tutorial/author/female-player"] = { tokens = {} },
        ["transition/trainer-name"] = { tokens = {} },
      },
      routes = {
        ["menu/bug-contest-level"] = { template = "template/bug-contest-level", inputs = { "caughtPokemonLevel" } },
        ["menu/bug-contest-remaining-balls"] = {
          template = "template/bug-contest-remaining-balls",
          inputs = { "remainingBalls" },
        },
        ["menu/give-up-move"] = { templates = { "prompt/give-up", "prompt/keep-battling" }, inputs = { "moveName" } },
        ["menu/vs-recorder-feedback"] = {
          variants = {
            "status/recorder-0",
            "status/recorder-1",
            "status/recorder-2",
            "status/recorder-3",
            "status/recorder-4",
            "status/recorder-5",
          },
          inputs = { "playbackStatus" },
          branches = {
            paused = { "status/recorder-0", "status/recorder-1" },
            corrupted = { "status/recorder-2", "status/recorder-3" },
            durationLimit = { "status/recorder-4", "status/recorder-5" },
          },
        },
        ["menu/bug-contest-caught-gender"] = {
          variants = { "label/bug-contest-gender-male", "label/bug-contest-gender-female" },
          inputs = { "caughtPokemonGender" },
        },
      },
    },
    transitions = {
      selectors = {
        ordinary = "ordinary",
        setupFallback = {
          inputs = { "battleType", "terrain", "timeOfDay" },
          terrainOffset = { cave = 4, water = 2 },
          offsetTimes = { "night", "late" },
          trainerOffset = 6,
          resolved = false,
        },
      },
      resourceSets = {},
      resources = { "menu/layout/bug-contest/palette" },
      messageRoutes = {
        trainerName = {
          message = "transition/trainer-name",
          inputs = { "trainerName" },
          resources = { "menu/layout/bug-contest/palette" },
        },
        rivalName = {
          message = "transition/trainer-name",
          inputs = { "rivalName" },
          resources = { "menu/layout/bug-contest/palette" },
        },
      },
      internalResources = {
        sprite = {
          palette = "menu/layout/bug-contest/palette",
          character = "menu/layout/bug-contest/character",
          cell = "menu/layout/bug-contest/cell",
          animation = "menu/layout/bug-contest/animation",
        },
      },
      routes = {
        ["trainer/red"] = {
          role = "red-trainer-transition",
          requiredContext = { "battleType", "trainerClass" },
          resources = { "menu/layout/bug-contest/palette" },
          assetGroups = { sprite = { palette = "menu/layout/bug-contest/palette" } },
          messages = { "transition/trainer-name" },
        },
      },
      selection = {
        trainerClassRoutes = { ["trainer/red"] = "trainer/red" },
        wildSpeciesRoutes = { ["wild/ho-oh"] = "trainer/red" },
        trainerRules = {
          inputs = { "trainerClass", "battleType" },
          specialBattle = {
            preserveRoutes = { "trainer/red" },
            defaultRoute = "trainer/red",
            doublesRoute = "trainer/red",
          },
          doublesRoute = "trainer/red",
          alternateTransitionRoute = "trainer/red",
        },
        wildRules = {
          inputs = { "wildSpecies", "battleType", "transitionMode" },
          specialMode = "wild-transition-special-case",
          fallbackRoute = "setup-fallback",
          doublesRoute = "trainer/red",
        },
        fallbackRoutes = fallbackRoutes,
      },
    },
    audioRoles = old.audioRoles,
    programs = old.programs,
    resources = old.resources,
    coverage = old.coverage,
  }
end

makeIntroMusic = function()
  local sequenceKey = "audio/sequence/SEQ_GS_VS_NORAPOKE"
  return {
    inputs = { "encounterKind" },
    inputTypes = { encounterKind = "battle-encounter-kind" },
    routes = {
      {
        key = "battle/music/wild",
        sequenceKey = sequenceKey,
        context = { "encounterKind" },
      },
    },
    sourceRoutes = {
      {
        sequenceSymbol = "SEQ_GS_VS_NORAPOKE",
        routeKey = "battle/music/wild",
        sequenceKey = sequenceKey,
        transitionFallback = false,
      },
    },
    kantoOverrides = { "wild/ordinary" },
    kantoSelection = {
      predicate = { "kanto-flypoint-flag", "map-region-nonzero" },
      appliesAfterCategorySelection = true,
      routes = { ["wild/ordinary"] = "kanto-wild" },
    },
    selectionRules = {
      trainer = {
        predicate = "battleType-trainer",
        classSource = "selected-opponent-trainer-class",
        categorySource = "NPCTrainerGetBattleIntroAndMusicParam",
        modifiers = { "frontierBattle", "doubleBattle", "tagBattle" },
      },
      wild = {
        predicate = "not-battleType-trainer",
        speciesSource = "first-living-opponent",
        specialSetupCase = "special-wild-transition-parameter",
        modifier = "doubleBattle",
      },
    },
    transitionFallbackIndependent = true,
    selectionSound = {
      key = "battle/music/menu-selection",
      eventInput = "menuSelectionEvent",
      sequenceKey = "audio/sequence/SEQ_SE_DP_SELECT",
    },
    sequenceClosures = {
      [sequenceKey] = {
        bankKey = "audio/bank/content/" .. string.rep("a", 40),
        player = { volume = 100, channelPriority = 64, playerPriority = 64 },
        sampleKeys = { "audio/sample/content/" .. string.rep("b", 40) },
        closureIdentity = string.rep("c", 40),
      },
      ["audio/sequence/SEQ_SE_DP_SELECT"] = {
        bankKey = "audio/bank/content/" .. string.rep("d", 40),
        player = { volume = 100, channelPriority = 64, playerPriority = 64 },
        sampleKeys = { "audio/sample/content/" .. string.rep("e", 40) },
        closureIdentity = string.rep("f", 40),
      },
    },
  }
end

return {
  manifest = manifest,
  scriptMessageProgramContext = scriptMessageProgramContext,
  makeIntroMusic = makeIntroMusic,
}
