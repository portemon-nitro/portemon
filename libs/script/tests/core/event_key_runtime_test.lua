-- Script runtime coverage for the save's own event-key selector and the
-- game-clear flag commands: each reads or writes exactly the flag/variable it
-- names and settles in its own source tick.

local Assert = require("tests.support.Assert")
local Runtime = require("libs.script.src.Runtime")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")

local T = {}

local function runWith(services)
  return {
    instance = { scriptId = "test.event-key", mode = "foreground", locals = {}, textArgs = {} },
    node = { nodeId = "n1" },
    tick = 1,
    input = {},
    services = services,
    semantics = RuntimeValues,
  }
end

local function worldWith(vars, flags)
  return {
    vars = vars or {},
    flags = flags or {},
    getVar = function(self, id)
      return self.vars[id] or 0
    end,
    setVar = function(self, id, value)
      self.vars[id] = value
    end,
    isFlagSet = function(self, id)
      return self.flags[id] == true
    end,
    setFlag = function(self, id)
      self.flags[id] = true
    end,
    clearFlag = function(self, id)
      self.flags[id] = nil
    end,
  }
end

local function var(id)
  return { value = "var", id = id }
end

function T.the_event_key_check_answers_the_stored_key_in_its_own_tick()
  local world = worldWith({ VAR_UNK_4043 = 0x06F2 })
  local run = runWith({ world = world })
  Assert.equal(
    Runtime.executeNode(
      { op = "check_event_key", variable = "VAR_UNK_4043", magic = 0x06F2, result = var("VAR_BASE") },
      run
    ),
    Runtime.OUTCOME_CONTINUE,
    "the selector settles without a wait"
  )
  Assert.equal(world.vars.VAR_BASE, 1, "the matching key answers one")
  Assert.equal(world.vars.VAR_UNK_4043, 0x06F2, "the selector never rewrites the stored key")
end

function T.the_second_event_key_is_compared_against_its_own_magic_word()
  local world = worldWith({ VAR_UNK_4044 = 0x06F2 })
  local run = runWith({ world = world })
  Runtime.executeNode(
    { op = "check_event_key", variable = "VAR_UNK_4044", magic = 0xAD7C, result = var("VAR_BASE") },
    run
  )
  Assert.equal(world.vars.VAR_BASE, 0, "a key stored for another event is refused")
end

function T.the_event_key_check_evaluates_an_aliased_output_before_writing()
  local world = worldWith({ VAR_UNK_4043 = 0x06F2, VAR_BASE = 7 })
  local run = runWith({ world = world })
  Runtime.executeNode(
    { op = "check_event_key", variable = "VAR_UNK_4043", magic = 0x06F2, result = var("VAR_UNK_4043") },
    run
  )
  Assert.equal(world.vars.VAR_UNK_4043, 1, "the answer lands in the named output after the source read")
end

function T.the_game_clear_commands_read_and_set_the_one_flag_they_name()
  local world = worldWith()
  local run = runWith({ world = world })
  Runtime.executeNode({ op = "check_game_clear", flag = "FLAG_GAME_CLEAR", result = var("VAR_BASE") }, run)
  Assert.equal(world.vars.VAR_BASE, 0, "an uncleared save answers zero")
  Assert.isNil(world.flags.FLAG_GAME_CLEAR, "the query never sets the flag it reads")
  Runtime.executeNode({ op = "set_game_clear", flag = "FLAG_GAME_CLEAR" }, run)
  Assert.isTrue(world.flags.FLAG_GAME_CLEAR == true, "the setter sets the save's clear flag")
  Runtime.executeNode({ op = "check_game_clear", flag = "FLAG_GAME_CLEAR", result = var("VAR_BASE") }, run)
  Assert.equal(world.vars.VAR_BASE, 1, "the query answers the flag the setter wrote")
end

return { tests = T }
