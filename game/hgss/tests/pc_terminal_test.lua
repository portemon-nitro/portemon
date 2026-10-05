local Assert = require("tests.support.Assert")
local PcTerminal = require("game.hgss.src.pc.PcTerminal")

local T = { tests = {} }

local function sourcePolicy()
  return {
    animationTag = 90,
    candidateBuildModelMembers = { 33, 138 },
    slots = {
      [0] = { role = "terminal.on", playMode = "forward" },
      [1] = { role = "terminal.off", playMode = "forward" },
    },
  }
end

function T.tests.terminal_effects_use_manifest_roles_and_release_once()
  local played, stopped = {}, {}
  local finished = false
  local prop = {
    play = function(_, role, mode)
      played[#played + 1] = { role = role, mode = mode }
    end,
    isFinished = function()
      return finished
    end,
    stop = function(_, role)
      stopped[#stopped + 1] = role
    end,
  }
  local terminal = PcTerminal.new({
    mailbox = { usedCount = function() return 2 end },
    photoAlbum = { usedCount = function() return 3 end },
    sourcePolicy = sourcePolicy(),
    resolveTerminalProp = function(propRef)
      Assert.equal(propRef, "pc_terminal", "the typed source prop reference is preserved")
      return prop
    end,
  })
  terminal:effect("start", "pc_terminal")
  terminal:effect("on", "pc_terminal")
  Assert.equal(played[1].role, "terminal.on", "slot zero uses its manifest role")
  Assert.equal(played[1].mode, "once", "terminal playback is one-shot")
  Assert.isFalse(terminal:effectFinished(), "the source wait remains pending before clip completion")
  finished = true
  Assert.isTrue(terminal:effectFinished(), "the exact active clip reports completion")
  terminal:effect("off", "pc_terminal")
  Assert.deepEqual(stopped, { "terminal.on" }, "a completed source clip releases before the next one starts")
  Assert.equal(played[2].role, "terminal.off", "slot one uses its manifest role")
  terminal:releaseEffect()
  terminal:releaseEffect()
  Assert.deepEqual(stopped, { "terminal.on", "terminal.off" }, "release stops the one active clip once")
end

function T.tests.counts_and_capsule_defer_read_canonical_owners_without_mutation()
  local terminal = PcTerminal.new({
    mailbox = { usedCount = function() return 4 end },
    photoAlbum = { usedCount = function() return 6 end },
    sourcePolicy = sourcePolicy(),
    resolveTerminalProp = function()
      error("counting does not resolve a prop")
    end,
  })
  Assert.equal(terminal:count("mailbox"), 4, "Mailbox count reads its owner")
  Assert.equal(terminal:count("photos"), 6, "Photo count reads its owner")
  Assert.equal(terminal:count("seals"), 0, "the alpha has no Seal Case inventory")
  Assert.equal(terminal:hallOfFameStatus(), 1, "missing saved HOF data follows the source warning branch")
  terminal:openCapsules()
end

return T
