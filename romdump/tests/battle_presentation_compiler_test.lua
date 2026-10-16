-- Source-backed effect context declarations are normalized by the producer.

local Assert = require("tests.support.Assert")
local T = {}

function T.move_power_callback_declares_its_event_time_context()
  local compiler = require("romdump.src.digest.battle.BattlePresentationCompiler")
  local sources = require("romdump.src.config.BattleAnimationSources")
  local route = assert(sources.resolveSemanticRoute("TACKLE"))
  local plan = assert(sources.resolveBattleAnimationCallback({ 28, 0 }))
  local previous = package.loaded["romdump.src.digest.battle.BattleAnimationCompiler"]
  package.loaded["romdump.src.digest.battle.BattleAnimationCompiler"] = {
    compile = function()
      return {
        entry = "main",
        instructions = {
          {
            op = "invoke-battle-animation-callback",
            callback = plan.callback,
            taskKind = plan.taskKind,
            taskContext = plan.context,
            parameters = plan.parameters,
          },
        },
        subprograms = {},
        taskKinds = { plan.taskKind },
      }
    end,
  }
  local romFs = {
    version = function()
      return "heartgold"
    end,
    metadata = function()
      return { sha1 = string.rep("a", 40) }
    end,
    openNarc = function(_, archiveSymbol)
      Assert.equal(archiveSymbol, route.archiveSymbol)
      return {
        readMember = function(_, memberId)
          Assert.equal(memberId, route.memberId)
          return "source bytes are supplied to the normalized compiler"
        end,
      }
    end,
  }

  local ok, effect, err = pcall(compiler.compileEffect, romFs, { versionId = "heartgold" }, "TACKLE")
  package.loaded["romdump.src.digest.battle.BattleAnimationCompiler"] = previous

  Assert.isTrue(ok, "producer compiles the source-normalized callback: " .. tostring(effect))
  Assert.notNil(effect, "effect contains the callback requiring event-time move power: " .. tostring(err))
  Assert.isNil(err)
  Assert.deepEqual(effect.requiredContext.movePower, { type = "battle-animation-move-power-u16" })
  Assert.deepEqual(effect.requiredContext.battlerTopology, { type = "battle-animation-battler-topology" })
  Assert.isNil(effect.requiredContext.movePower.value, "producer declares the event-time type, not a guessed value")
end

function T.picture_offset_callback_declares_battler_topology()
  local compiler = require("romdump.src.digest.battle.BattlePresentationCompiler")
  local sources = require("romdump.src.config.BattleAnimationSources")
  local effectKey = "BATTLE_ANIMATION_HAPPY"
  local route = assert(sources.resolveSemanticRoute(effectKey))
  local plan = assert(sources.resolveBattleAnimationCallback({ 57, 4, 4, 0, 8, 264 }))
  local previous = package.loaded["romdump.src.digest.battle.BattleAnimationCompiler"]
  package.loaded["romdump.src.digest.battle.BattleAnimationCompiler"] = {
    compile = function()
      return {
        entry = "main",
        instructions = {
          {
            op = "invoke-battle-animation-callback",
            callback = plan.callback,
            taskKind = plan.taskKind,
            taskContext = plan.context,
            parameters = plan.parameters,
          },
        },
        subprograms = {},
        taskKinds = { plan.taskKind },
      }
    end,
  }
  local romFs = {
    version = function()
      return "heartgold"
    end,
    metadata = function()
      return { sha1 = string.rep("a", 40) }
    end,
    openNarc = function(_, archiveSymbol)
      Assert.equal(archiveSymbol, route.archiveSymbol)
      return {
        readMember = function(_, memberId)
          Assert.equal(memberId, route.memberId)
          return "source bytes are supplied to the normalized compiler"
        end,
      }
    end,
  }

  local ok, effect, err = pcall(compiler.compileEffect, romFs, { versionId = "heartgold" }, effectKey)
  package.loaded["romdump.src.digest.battle.BattleAnimationCompiler"] = previous

  Assert.isTrue(ok, "producer compiles the source-normalized callback: " .. tostring(effect))
  Assert.notNil(effect, "effect carries the target picture callback: " .. tostring(err))
  Assert.isNil(err)
  Assert.deepEqual(effect.requiredContext.battlerTopology, { type = "battle-animation-battler-topology" })
end

function T.native_shadow_compiler_extracts_the_four_selected_source_rectangles()
  local compiler = require("romdump.src.digest.battle.BattlePresentationCompiler")
  local bit = require("bit")
  local surface = {}
  for y = 0, 79 do
    local value = y < 16 and 0x11 or y < 32 and 0x22 or y < 48 and 0x33 or 0x44
    for x = 0, 79 do
      surface[y * 80 + x + 1] = x < 40 and value or 0x55
    end
  end
  surface[1], surface[2] = 0, 0
  local scanned = {}
  local seed = 0x1234
  for wordOffset = 0, 3199 do
    local plain = surface[wordOffset * 2 + 1] + surface[wordOffset * 2 + 2] * 256
    local encoded = bit.bxor(plain, seed % 65536)
    scanned[#scanned + 1] = string.char(encoded % 256, math.floor(encoded / 256))
    local low, high = seed % 65536, math.floor(seed / 65536)
    local lowProduct = low * 20077 + 24691
    local highProduct = (low * 16838 + high * 20077 + math.floor(lowProduct / 65536)) % 65536
    seed = lowProduct % 65536 + highProduct * 65536
  end
  local palette = { colors = {} }
  for index = 0, 15 do
    palette.colors[index + 1] = { r = index * 10, g = 0, b = 0 }
  end
  local image = compiler.compileShadowImage({ depth = 3, tiles = table.concat(scanned) }, palette)

  Assert.equal(image.width, 64, "shadow metadata keeps the native 64-pixel width")
  Assert.equal(image.height, 64, "four native shadow-size regions are staged vertically")
  local function pixel(x, y)
    local offset = (y * image.width + x) * 4 + 1
    return {
      string.byte(image.pixels, offset),
      string.byte(image.pixels, offset + 1),
      string.byte(image.pixels, offset + 2),
      string.byte(image.pixels, offset + 3),
    }
  end
  Assert.deepEqual(pixel(4, 0), { 10, 0, 0, 255 }, "size zero reads the copied first shadow rows")
  Assert.deepEqual(pixel(4, 16), { 10, 0, 0, 255 }, "size one aliases the source size-zero rectangle")
  Assert.deepEqual(pixel(4, 32), { 20, 0, 0, 255 }, "size two selects the next native atlas rows")
  Assert.deepEqual(pixel(4, 48), { 30, 0, 0, 255 }, "size three selects the final native atlas rows")
end

return { tests = T }
