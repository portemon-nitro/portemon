-- Producer-side HGSS mart selectors and audited source tables.
-- Source authority: pret/pokeheartgold@9d8b7591f09b65804da2fb2dfd56f320633e0d36,
-- src/scrcmd_mart.c, asm/overlay_31.s, and src/overlay_03/shop_menu.c.

local Assert = require("tests.support.Assert")

local T = {}

local function sources()
  return require("romdump.src.config.MartSources")
end

function T.provenance_and_resources_use_semantic_aliases()
  local MartSources = sources()
  Assert.equal(MartSources.provenance.repo, "pret/pokeheartgold")
  Assert.equal(MartSources.provenance.commit, "9d8b7591f09b65804da2fb2dfd56f320633e0d36")
  local listed = {}
  for _, path in ipairs(MartSources.provenance.sources) do
    listed[path] = true
  end
  for _, path in ipairs({ "src/scrcmd_mart.c", "asm/overlay_31.s", "src/overlay_03/shop_menu.c" }) do
    Assert.isTrue(listed[path], "provenance must name " .. path)
  end

  Assert.equal(MartSources.archive.alias, "NARC_a_0_6_0")
  Assert.equal(MartSources.archive.symbol, "NARC_a_0_6_0")
  Assert.equal(MartSources.resdat.alias, "NARC_data_resdat")
  Assert.equal(MartSources.resdat.symbol, "NARC_data_resdat")
  Assert.deepEqual(MartSources.resdat.members, { animation = 64, cell = 65, char = 66, palette = 67, header = 88 })
  Assert.equal(MartSources.itemIcons.alias, "NARC_itemtool_itemdata_item_icon")
  Assert.equal(MartSources.itemIcons.symbol, "NARC_itemtool_itemdata_item_icon")
  Assert.deepEqual(MartSources.itemIcons.members, { animation = 0, cell = 1 })
  Assert.deepEqual(MartSources.itemIcons.basis, { width = 32, height = 32, anchor = "center" })
  Assert.equal(MartSources.messages.archive.alias, "messages")
  Assert.equal(MartSources.messages.archive.symbol, "NARC_msgdata_msg")
  Assert.equal(MartSources.messages.bank, 435)
  Assert.deepEqual(MartSources.messages.descriptionSources, {
    seals = {
      bank = 434,
      indexOffset = -1,
      source = "src/unk_02091054.c::sub_020910B8",
    },
    decorations = {
      bank = 737,
      indexOffset = 138,
      source = "src/overlay_03/shop_menu.c::ov03_022573D4",
    },
  })

  local main, lower, controls = MartSources.archive.resources.main, MartSources.archive.resources.lower,
    MartSources.archive.resources.controls
  Assert.deepEqual(main, {
    char = 0,
    palette = 1,
    itemsScreen = 2,
    legacyScreen = 3,
    chromeChars = { 4, 7 },
    chromeScreens = { 5, 6, 8, 9 },
    chromePalette = 10,
  })
  Assert.deepEqual(lower, {
    palette = 15,
    char = 16,
    browseScreen = 17,
    countLayerScreen = 18,
    quantityScreen = 19,
    confirmScreen = 20,
  })
  Assert.deepEqual(controls, { palette = 22, char = 23, cell = 24, animation = 25 })

  Assert.deepEqual(MartSources.messages.roles, {
    insufficientMoney = 11,
    quantityPrompt = 12,
    moneyConfirm = 14,
    itemReceived = 15,
    noRoom = 16,
    cancelLabel = 17,
    moneyPrice = 18,
    pointsPrice = 19,
    premierBonus = 20,
    sealReceived = 23,
    sealFull = 24,
    boughtToday = 25,
    alreadyOwned = 26,
    moneyLabel = 30,
    moneyBalance = 31,
    pointsBalance = 32,
    pointsLabel = 33,
    ownedLabel = 35,
    ownedCount = 36,
    quantityTotal = 38,
    buyLabel = 42,
    pageNumber = 43,
    tensDigit = 44,
    unitsDigit = 45,
    pointsConfirm = 46,
    insufficientPoints = 48,
    pointsReceived = 49,
  })

  Assert.deepEqual(MartSources.controls.animations, {
    selectionEntry = 19,
    restore = 7,
    increment = 13,
    decrement = 15,
    pagePrevious = 6,
    pageNext = 26,
  })
  Assert.equal(MartSources.controls.browseFocus.cell, 0)
  Assert.equal(MartSources.controls.pagePrevious.cell, 2)
  Assert.equal(MartSources.controls.pageNext.cell, 3)
  Assert.equal(MartSources.controls.pageFocus.cell, 4)
  Assert.equal(MartSources.controls.cancel.cell, 6)
  Assert.equal(MartSources.controls.cancelSelected.cell, 7)
  Assert.equal(MartSources.controls.increment.cell, 12)
  Assert.equal(MartSources.controls.incrementSelected.cell, 13)
  Assert.equal(MartSources.controls.decrement.cell, 14)
  Assert.equal(MartSources.controls.decrementSelected.cell, 15)
  Assert.equal(MartSources.controls.invisible.cell, 19)
  Assert.equal(MartSources.controls.confirm.cell, 20)
  Assert.equal(MartSources.controls.quantityCancel.cell, 22)
end

function T.source_stock_tables_keep_required_counts_and_pointer_order_sentinels()
  local MartSources = sources()
  local stock = MartSources.stockTables
  Assert.equal(stock.expectedCounts.normalTiers, 19)
  Assert.equal(stock.expectedCounts.special, 30)
  Assert.equal(stock.expectedCounts.athlete, 14)
  Assert.equal(stock.expectedCounts.dataCard, 5)
  Assert.equal(stock.expectedCounts.seals, 7)
  Assert.equal(stock.expectedCounts.decorations, 2)
  Assert.equal(#stock.normalTiers, stock.expectedCounts.normalTiers)
  Assert.equal(#stock.specialStocks, stock.expectedCounts.special)
  Assert.equal(#stock.athleteStocks, stock.expectedCounts.athlete)
  Assert.equal(#stock.dataCardStocks, stock.expectedCounts.dataCard)
  Assert.equal(#stock.sealStocks, stock.expectedCounts.seals)
  Assert.equal(#stock.decorationStocks, stock.expectedCounts.decorations)

  Assert.equal(stock.normalTierSource, "src/scrcmd_mart.c::_020FBF22 via ScrCmd_MartBuy")
  Assert.deepEqual(stock.normalTiers[1], { itemKey = "POKE_BALL", minimumTier = 1 })
  Assert.deepEqual(stock.normalTiers[2], { itemKey = "GREAT_BALL", minimumTier = 3 })
  Assert.deepEqual(stock.normalTiers[19], { itemKey = "MAX_REPEL", minimumTier = 4 })

  Assert.equal(stock.specialSourceOrder, "src/scrcmd_mart.c::_0210FA3C via ScrCmd_SpecialMartBuy")
  Assert.equal(stock.specialStocks[1][1], "AIR_MAIL")
  Assert.equal(stock.specialStocks[2][1], "TUNNEL_MAIL")
  Assert.equal(stock.specialStocks[4][1], "POTION")
  Assert.equal(stock.specialStocks[8][1], "TM70")
  Assert.equal(stock.specialStocks[20][1], "POKE_BALL")
  Assert.equal(stock.specialStocks[21][1], "TM21")
  Assert.equal(stock.specialStocks[30][1], "GREAT_BALL")

  Assert.equal(stock.athleteSourceOrder, "src/scrcmd_mart.c::_0210FA04")
  Assert.equal(stock.athleteStocks[1][4][1], "MOOMOO_MILK")
  Assert.equal(stock.athleteStocks[1][4][2], 100)
  Assert.equal(stock.athleteStocks[14][4][1], "MOOMOO_MILK")
  Assert.equal(stock.athleteStocks[14][4][2], 100)
  Assert.equal(stock.athleteStocks[14][1][1], "GRN_APRICORN")
  Assert.equal(stock.athleteStocks[14][1][2], 200)
  Assert.equal(stock.dataCardStocks[5][3][1], "DATA_CARD_27")
  Assert.equal(stock.dataCardStocks[5][3][2], 9999)
  Assert.equal(stock.dataCardSourceOrder, "src/scrcmd_mart.c::_0210F9D4")
  Assert.equal(stock.athleteWeekOrder, "Sunday..Saturday before National Dex, then after National Dex")

  -- Seal and decoration identifiers are separate source namespaces, even
  -- though their source numbers overlap other HGSS identities.
  Assert.equal(stock.sealStocks[1][1], "HEART_A")
  Assert.equal(stock.decorationStocks[1][1], "YELLOW_CUSHION")
  Assert.equal(stock.decorationStocks[2][1], "MUNCHLAX_DOLL")
  Assert.deepEqual(stock.sealIds, {
    HEART_A = 1,
    HEART_B = 2,
    HEART_C = 3,
    HEART_D = 4,
    HEART_E = 5,
    HEART_F = 6,
    STAR_A = 7,
    STAR_B = 8,
    STAR_C = 9,
    STAR_D = 10,
    STAR_E = 11,
    STAR_F = 12,
    LINE_A = 13,
    LINE_B = 14,
    LINE_C = 15,
    LINE_D = 16,
    SMOKE_A = 17,
    SMOKE_B = 18,
    SMOKE_C = 19,
    SMOKE_D = 20,
    ELE_A = 21,
    ELE_B = 22,
    ELE_C = 23,
    ELE_D = 24,
    FOAMY_A = 25,
    FOAMY_B = 26,
    FOAMY_C = 27,
    FOAMY_D = 28,
    FIRE_A = 29,
    FIRE_B = 30,
    FIRE_C = 31,
    FIRE_D = 32,
    PARTY_A = 33,
    PARTY_B = 34,
    PARTY_C = 35,
    PARTY_D = 36,
    FLORA_A = 37,
    FLORA_B = 38,
    FLORA_C = 39,
    FLORA_D = 40,
    FLORA_E = 41,
    FLORA_F = 42,
    SONG_A = 43,
    SONG_B = 44,
    SONG_C = 45,
    SONG_D = 46,
    SONG_E = 47,
    SONG_F = 48,
    SONG_G = 49,
  })
  Assert.deepEqual(stock.decorationIds, {
    YELLOW_CUSHION = 7,
    CUPBOARD = 22,
    TV = 25,
    REFRIGERATOR = 26,
    PRETTY_SINK = 27,
    MUNCHLAX_DOLL = 115,
    BONSLY_DOLL = 116,
    MIME_JR__DOLL = 117,
    MANTYKE_DOLL = 119,
    BUIZEL_DOLL = 120,
    CHATOT_DOLL = 121,
  })
end

function T.count_patches_distinguish_every_visible_count_from_the_invisible_empty_state()
  local patches = sources().countPatches
  Assert.equal(patches.source, "asm/overlay_31.s::ov31_0225E060/ov31_0225EF48")
  Assert.equal(patches.coordinateUnit, "tile")
  Assert.equal(patches.tileSize, 8)

  for count = 0, 6 do
    Assert.isTrue(type(patches[count]) == "table", "count " .. count .. " has an explicit patch list")
  end
  Assert.equal(#patches[0], 1)
  Assert.equal(patches[0][1].kind, "fill")
  Assert.equal(patches[0][1].x, 0)
  Assert.equal(patches[0][1].y, 4)
  Assert.equal(patches[0][1].width, 32)
  Assert.equal(patches[0][1].height, 16)
  Assert.equal(#patches[1], 3)
  Assert.equal(patches[1][1].kind, "copy")
  Assert.equal(patches[1][1].sourceX, 0)
  Assert.equal(patches[1][1].sourceY, 19)
  Assert.equal(patches[1][2].kind, "fill")
  Assert.equal(patches[1][3].kind, "fill")
  Assert.equal(patches[1][3].x, 16)
  Assert.equal(patches[1][3].y, 4)
  Assert.deepEqual(patches[1][3], {
    kind = "fill",
    x = 16,
    y = 4,
    width = 16,
    height = 16,
    fillValue = 0,
    mode = 0,
  }, "the source count patch clears the right-hand block at tile 16,4")
  Assert.equal(#patches[2], 3)
  Assert.equal(patches[2][2].kind, "copy")
  Assert.equal(patches[2][2].sourceX, 16)
  Assert.equal(patches[2][2].sourceY, 19)
  Assert.equal(patches[2][3].width, 32)
  Assert.equal(#patches[3], 4)
  Assert.equal(patches[3][1].destY, 14)
  Assert.equal(patches[3][3].destY, 9)
  Assert.equal(#patches[4], 3)
  Assert.equal(patches[4][1].destY, 14)
  Assert.equal(#patches[5], 2)
  Assert.equal(patches[5][1].sourceX, 16)
  Assert.equal(patches[5][1].sourceY, 19)
  Assert.equal(patches[5][1].destY, 14)
  Assert.deepEqual(patches[6], {}, "six visible slots require no tilemap surgery")

  local signatures = {}
  for count = 0, 6 do
    local parts = {}
    for _, patch in ipairs(patches[count]) do
      parts[#parts + 1] = table.concat({ patch.kind, patch.sourceX or "-", patch.sourceY or "-", patch.x or "-", patch.y or "-",
        patch.sourceY or "-", patch.destY or "-", patch.width, patch.height }, ":")
    end
    local signature = table.concat(parts, "|")
    Assert.isNil(signatures[signature], "count " .. count .. " must keep its own source patch state")
    signatures[signature] = count
  end
end

function T.animation_roles_retain_invisible_cells_and_source_tick_units()
  local controls = sources().controls
  Assert.equal(controls.invisible.cell, 19)
  Assert.deepEqual(controls.selectionEntryTicks, { 6, 6, 6, 6 })
  Assert.equal(controls.feedback.selectedTicks, 4)
  Assert.equal(controls.feedback.restoredTicks, 2)
  Assert.equal(controls.feedback.dispatchTicks, 1)
end

return { tests = T }
