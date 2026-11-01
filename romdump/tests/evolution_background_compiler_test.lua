local Assert = require("tests.support.Assert")

local T = {}

local function u16(value)
  return string.char(value % 256, math.floor(value / 256) % 256)
end

local function u32(value)
  return u16(value % 65536) .. u16(math.floor(value / 65536))
end

local function block(magic, payload)
  return magic:reverse() .. u32(8 + #payload) .. payload
end

local function container(magic, payload)
  local body = block(payload.magic, payload.bytes)
  return magic .. "\255\254" .. u16(0x0100) .. u32(0x10 + #body) .. u16(0x10) .. u16(1) .. body
end

local function characters()
  local tiles = string.rep("\17", 32)
  local payload = u16(8) .. u16(0x20) .. u32(3) .. u16(0) .. u16(0) .. u32(0) .. u32(#tiles) .. u32(0x18) .. tiles
  return container("RGCN", { magic = "CHAR", bytes = payload })
end

local function palette()
  local colors = {}
  for color = 0, 15 do
    colors[#colors + 1] = u16(color)
  end
  local payload = string.char(3, 0) .. u16(16) .. u32(0) .. u32(12) .. table.concat(colors)
  return container("NCLR", { magic = "PLTT", bytes = payload })
end

local function screen()
  local entries = {}
  for _ = 1, 32 * 24 do
    entries[#entries + 1] = u16(0)
  end
  local payload = u16(256) .. u16(192) .. u32(0) .. u32(#entries * 2) .. table.concat(entries)
  return container("RCSN", { magic = "SCRN", bytes = payload })
end

local function cell()
  local object = u16(0x00D8) .. u16(0x01D8) .. u16(0)
  local payload = u16(1) .. u16(0) .. u32(0x18) .. u32(1) .. string.rep("\0", 12) .. u16(1) .. u16(0) .. u32(0) .. object
  return container("RECN", { magic = "CEBK", bytes = payload })
end

local function animation()
  local header = u16(4) .. u16(6) .. u32(0x18) .. u32(0x58) .. u32(0x88) .. string.rep("\0", 8)
  local sequences = u16(1) .. u16(0) .. u32(0x00010000) .. u32(1) .. u32(0)
    .. u16(2) .. u16(0) .. u32(0x00010000) .. u32(1) .. u32(8)
    .. u16(1) .. u16(0) .. u32(0x00010000) .. u32(1) .. u32(24)
    .. u16(2) .. u16(0) .. u32(0x00010000) .. u32(1) .. u32(32)
  local durations = { 2, 3, 6, 4, 5, 7 }
  local frames = {}
  local frameData = {}
  for frameIndex, duration in ipairs(durations) do
    frames[#frames + 1] = u32((frameIndex - 1) * 4) .. u16(duration) .. u16(0)
    frameData[#frameData + 1] = u16(0) .. u16(0)
  end
  return container("RNAN", { magic = "ABNK", bytes = header .. sequences .. table.concat(frames) .. table.concat(frameData) })
end

function T.evolution_graphics_compiles_exact_main_and_sub_members_to_screen_rasters()
  local compiler = require("romdump.src.digest.battle.BattlePresentationCompiler")
  local members = {}
  members["NARC_a_1_1_5"] = { [0] = characters(), [1] = screen(), [8] = palette() }
  members["NARC_a_2_3_7"] = {
    [0] = palette(),
    [1] = characters(),
    [10] = screen(),
    [15] = palette(),
    [16] = characters(),
    [17] = screen(),
    [11] = palette(),
    [12] = characters(),
    [13] = cell(),
    [14] = animation(),
  }
  members["NARC_graphic_font"] = { [9] = palette() }
  local romFs = {
    openNarc = function(_, archiveSymbol)
      local archive = assert(members[archiveSymbol], "the compiler selects a source archive")
      return {
        readMember = function(_, memberId)
          return archive[memberId]
        end,
      }
    end,
  }
  local compiled = compiler.compileEvolutionGraphics(romFs)
  Assert.equal(compiled.images.main.width, 256, "main background uses the retail screen width")
  Assert.equal(compiled.images.main.height, 192, "main background is cropped to the visible retail screen")
  Assert.equal(compiled.images.sub.width, 256, "sub background uses the retail screen width")
  Assert.equal(compiled.images.sub.height, 192, "sub background is cropped to the visible retail screen")
  Assert.equal(compiled.images.menu.width, 256, "the lower menu background uses the retail screen width")
  Assert.equal(compiled.images.menu.height, 192, "the lower menu background is screen-sized")
  Assert.equal(compiled.provenance.main.members.characters, 0, "main CHAR comes from the named evolution member")
  Assert.equal(compiled.provenance.main.members.screen, 1, "main screen map comes from its source member")
  Assert.equal(compiled.provenance.main.paletteMember, 8, "main palette comes from its source member")
  Assert.equal(compiled.provenance.sub.members.characters, 16, "the always-visible sub CHAR comes from member 16")
  Assert.equal(compiled.provenance.sub.members.screen, 17, "the always-visible sub map comes from member 17")
  Assert.equal(compiled.provenance.sub.paletteMember, 0, "the always-visible sub palette comes from member zero")
  Assert.equal(compiled.provenance.menu.members.characters, 1, "the menu sub CHAR comes from member 1")
  Assert.equal(compiled.provenance.menu.members.screen, 10, "the sub menu map comes from member 10")
  Assert.equal(compiled.provenance.menu.paletteMember, 15, "the sub menu palette comes from member 15")
  Assert.equal(#compiled.records.menuTextPalette.colors, 16, "the evolution printer exposes its loaded 16-color font bank")
  Assert.deepEqual(compiled.records.menuTextPalette.colors[2], { r = 8, g = 0, b = 0 }, "menu foreground RGB comes from font palette slot 1")
  Assert.deepEqual(compiled.records.menuTextPalette.colors[3], { r = 16, g = 0, b = 0 }, "menu shadow RGB comes from font palette slot 2")
  Assert.equal(compiled.provenance.menuTextPalette.archiveSymbol, "NARC_graphic_font", "menu font palette source remains producer provenance")
  Assert.equal(compiled.provenance.menuTextPalette.memberId, 9, "menu font palette member remains producer provenance")
  Assert.equal(compiled.provenance.menuTextPalette.destinationBank, 15, "menu font destination bank remains producer provenance")
  Assert.equal(compiled.records.cursor.animations.idle.frames[1].sourceFrame, 0, "the idle cursor retains source frame indices")
  Assert.equal(compiled.records.cursor.animations.idle.frames[1].durationTicks, 3, "the idle cursor retains source frame duration")
  Assert.equal(compiled.records.cursor.animations.idle.frames[2].durationTicks, 6, "the idle cursor uses retail animation 1")
  Assert.equal(compiled.records.cursor.animations.select.frames[1].durationTicks, 5, "the select cursor uses retail animation 3")
  Assert.equal(compiled.records.cursor.animations.select.frames[2].durationTicks, 7, "the select cursor preserves completion timing")
  Assert.equal(compiled.records.cursor.animations.idle.frames[1].drawableKey, "battle:evolution-cursor:idle:0", "idle frames have semantic drawable keys")
  Assert.equal(compiled.records.cursor.animations.select.frames[1].image, "assets/generated/battle/evolution-cursor-select-0.png", "select frames name normalized images")
  Assert.equal(compiled.provenance.cursor.members.palette, 11, "cursor palette member stays producer provenance")
  Assert.equal(compiled.provenance.cursor.members.characters, 12, "cursor character member stays producer provenance")
  Assert.equal(compiled.provenance.cursor.members.cell, 13, "cursor cell member stays producer provenance")
  Assert.equal(compiled.provenance.cursor.members.animation, 14, "cursor animation member stays producer provenance")
  Assert.equal(compiled.provenance.cursor.sequences.idle, 1, "the cursor idle sequence stays producer provenance")
  Assert.equal(compiled.provenance.cursor.sequences.select, 3, "the cursor select sequence stays producer provenance")
  Assert.equal(compiled.images["cursor-idle-0"].width, 8, "cursor source frames are rasterized from the decoded source cell")
end

function T.evolution_messages_are_tokenized_under_semantic_keys_with_producer_source_selection()
  local compiler = require("romdump.src.digest.battle.BattlePresentationCompiler")
  local bank = { messages = {} }
  local expected = {
    4,
    915,
    916,
    917,
    918,
    919,
    1181,
    1182,
    1186,
    1187,
    1193,
    1194,
    1195,
    1197,
    1198,
    1199,
    1200,
    1201,
    1202,
  }
  for _, messageId in ipairs(expected) do
    local raw = { 0xFFFF }
    if messageId == 1186 or messageId == 1187 then
      raw = { 0xFFFE, 0x0106, 2, 0, 0, 0xFFFF }
    end
    bank.messages[messageId + 1] = { raw = raw }
  end
  local entries, provenance = compiler.compileEvolutionMessageEntries(bank)
  for _, messageId in ipairs(expected) do
    local key = "evolution/" .. tostring(messageId)
    Assert.isTrue(type(entries[key].tokens) == "table", "every scene message is passed through the authoritative tokenizer")
    Assert.equal(provenance[key].bankRole, "scriptController", "source bank role remains producer provenance")
    Assert.equal(provenance[key].memberId, 197, "physical message bank member stays out of runtime records")
    Assert.equal(provenance[key].messageId, messageId, "producer provenance names the retail message id")
  end
  for _, messageId in ipairs({ 1186, 1187 }) do
    local key = "evolution/" .. tostring(messageId)
    local hasMove = false
    for _, token in ipairs(entries[key].tokens) do
      if
        token.kind == "substitution"
        and token.control == 0x0106
        and token.args[1] == 0
        and token.args[2] == 0
      then
        hasMove = true
      end
    end
    Assert.isTrue(hasMove, "give-up menu labels retain the source move-name placeholder")
  end
end

function T.retail_evolution_cursor_rasters_match_the_source_composite(context)
  if context == nil or type(context.hasCapability) ~= "function" or not context:hasCapability("rom_dump") then
    Assert.isTrue(context ~= nil, "the runner provides a skip context without a ready dump")
    context:skip("EvolutionScene cursor bounds are checked against a ready user-owned dump")
  end
  local RomImporter = require("romdump.src.source.RomImporter")
  if not RomImporter.isReady("heartgold") then
    context:skip("EvolutionScene cursor source regression needs the registered HeartGold dump")
  end
  local RomSourcePath = require("tests.rom.support.RomSourcePath")
  local romFs, romSource = RomSourcePath.openReader("heartgold")
  Assert.isTrue(romFs ~= nil, "the registered HeartGold source opens: " .. tostring(romSource))
  assert(romFs ~= nil, "an unavailable HeartGold source fails above")
  local compiler = require("romdump.src.digest.battle.BattlePresentationCompiler")
  local ok, compiled = pcall(compiler.compileEvolutionGraphics, romFs)
  romFs:close()
  romSource:release()
  Assert.isTrue(ok, "the retail cursor source compiles: " .. tostring(compiled))
  assert(ok, "invalid retail cursor source fails above")
  for _, animationRole in ipairs({ "idle", "select" }) do
    local frames = compiled.records.cursor.animations[animationRole].frames
    local sizes = {}
    for frameIndex, frame in ipairs(frames) do
      local raster = compiled.images["cursor-" .. animationRole .. "-" .. (frameIndex - 1)]
      sizes[#sizes + 1] = table.concat({
        tostring(frame.sourceFrame),
        tostring(raster.width) .. "x" .. tostring(raster.height),
        tostring(frame.rasterOffset.x) .. "," .. tostring(frame.rasterOffset.y),
        tostring(frame.durationTicks),
        tostring(frame.userAttr),
      }, "@")
      Assert.deepEqual(
        { raster.width, raster.height },
        { frame.width, frame.height },
        animationRole .. " source frame metadata matches its rasterized cell"
      )
    end
    Assert.equal(
      table.concat(sizes, ","),
      animationRole == "idle"
        and "0@256x48@-128,-24@4@0"
        or "0@1x1@0,0@4@0,1@256x48@-128,-24@4@0,2@1x1@0,0@4@0,3@256x48@-128,-24@2@0"
    )
    Assert.deepEqual(compiled.provenance.cursor.sequences, { idle = 1, select = 3 }, "source sequences are exact")
  end
  Assert.equal(#compiled.records.cursor.animations.idle.frames, 1, "retail idle is one full-width source cell")
  Assert.equal(#compiled.records.cursor.animations.select.frames, 4, "retail selection retains its four-frame sequence")
  Assert.equal(compiled.records.cursor.animations.idle.playMode, "forward_loop", "the idle cursor loops")
  Assert.equal(compiled.records.cursor.animations.select.playMode, "forward", "the select cursor terminates")
  Assert.deepEqual(
    {
      compiled.records.cursor.animations.select.frames[1].durationTicks,
      compiled.records.cursor.animations.select.frames[2].durationTicks,
      compiled.records.cursor.animations.select.frames[3].durationTicks,
      compiled.records.cursor.animations.select.frames[4].durationTicks,
    },
    { 4, 4, 4, 2 },
    "selection retains the retail completion timing"
  )
end

return { tests = T }
