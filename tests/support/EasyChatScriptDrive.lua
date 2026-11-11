-- Shared driver for the word-script acceptance journeys: boots no games
-- itself, only translates the semantic editor vocabulary (confirm, cancel,
-- navigate) into production input edges and waits on production host
-- state. Suites own their scenarios; this rig owns only the driving.

local Assert = require("tests.support.Assert")

local Drive = {}

---@param moduleName string
---@param missingMessage string
---@return table
function Drive.requireFeature(moduleName, missingMessage)
  local ok, mod = pcall(require, moduleName)
  if not ok then
    error(missingMessage, 0)
  end
  assert(type(mod) == "table", missingMessage)
  return mod --[[@as table]]
end

-- Requires the three script-integration owners together: the domain
-- service, the single script-owned editor host, and the async source
-- protocol task. The failure names the missing behaviour, never a path.
---@return table service, table host, table task
function Drive.requireScriptModules()
  local Service = Drive.requireFeature(
    "game.hgss.src.easychat.EasyChatScriptService",
    "the field script has no word domain service yet: no word command can resolve its operands, results, or save policy"
  )
  local Host = Drive.requireFeature(
    "game.hgss.src.easychat.EasyChatScriptHost",
    "the field script has no word editor host yet: no script can open the shared editor or own its lifetime"
  )
  local Task = Drive.requireFeature(
    "libs.hgss.src.script.tasks.EasyChatTask",
    "the field script has no word editor task yet: no script can leave the field, wait on the editor, or publish ordered results"
  )
  return Service, Host, Task
end

-- Binds the documented headless preparation lease: the acceptance runtime
-- never realizes GPU images, so the editor commits a ready bundle of stub
-- assets at the field preparation seam instead of the real image pool.
-- The stub stands in for the GPU-owned bundle only; input, lifecycle, and
-- results stay production. Returns the binding identity and a release
-- counter proving every per-open lease releases exactly once.
---@param runtime table
---@return unknown bindingId, fun(): integer releases
function Drive.bindHeadlessEditor(runtime)
  local releases = 0
  local bind = assert(runtime.bindEasyChatPreparation, "the field runtime binds the word editor preparation lease")
  local binding = bind(runtime, function()
    return {
      prepare = function()
        return { kind = "ready", assets = {} }
      end,
      release = function()
        releases = releases + 1
      end,
    }
  end)
  return binding, function()
    return releases
  end
end

local DIRECTIONS = { up = "north", down = "south", left = "west", right = "east" }

-- Drives semantic editor events through the same production input edges
-- the modal yes/no and menu flows consume: action, cancel, and direction
-- presses with one settled tick each. No fixed sleeps and no direct
-- screen calls; the script-owned host stays the only update lane.
---@param game table
---@param events table[]
function Drive.send(game, events)
  for _, event in ipairs(events) do
    if event.type == "confirm" then
      game.runtime:pressAction("acceptance")
      game:step()
      game.runtime:releaseAction("acceptance")
    elseif event.type == "cancel" then
      game.runtime:pressCancel("acceptance")
      game:step()
      game.runtime:releaseCancel("acceptance")
    elseif event.type == "navigate" then
      local direction = assert(DIRECTIONS[event.direction], "editor navigation names up, down, left, or right")
      game.runtime:press(direction, "acceptance")
      game:step()
      game.runtime:release(direction, "acceptance")
    else
      game:step()
    end
  end
end

-- The single script-owned editor host composed into the field runtime.
---@param game table
---@return table host
function Drive.hostOf(game)
  return assert(
    game.runtime.easyChatScriptHost,
    "the field runtime composes the single script-owned word editor host before any word script runs"
  )
end

-- Steps the production runtime until the script-owned editor owns a
-- pending child. The child opens on its own after fades and dialogue;
-- no input is needed to reach this boundary.
---@param game table
---@param budget integer?
---@return table host
function Drive.waitEditorOpen(game, budget)
  local host = Drive.hostOf(game)
  for _ = 1, budget or 480 do
    if host:isActive() then
      return host
    end
    game:step()
  end
  error("the word script never opened its script-owned editor", 0)
end

-- Steps until the pending editor is ready for input: preparation
-- complete and the shared editor input key owned. A stall fails with
-- the stalled status instead of hanging the suite.
---@param game table
---@param host table
---@param budget integer?
---@return table status
function Drive.waitEditorReady(game, host, budget)
  for _ = 1, budget or 240 do
    local status = host:status()
    if status ~= nil and status.preparing == false and status.uiInput == "easy-chat" then
      return status
    end
    game:step()
  end
  local status = host:status()
  local detail = "no status"
  if status ~= nil then
    detail = "preparing=" .. tostring(status.preparing) .. " uiInput=" .. tostring(status.uiInput)
  end
  error("the script-owned editor never becomes ready for input (" .. detail .. ")", 0)
end

-- Reads the one-shot terminal result after the exit fade completes. The
-- result is unavailable while the fade runs and reads exactly once.
---@param game table
---@param host table
---@param handle unknown
---@param budget integer?
---@return table result
function Drive.takeResult(game, host, handle, budget)
  for _ = 1, budget or 240 do
    local result = host:result(handle)
    if result ~= nil then
      return result
    end
    game:step()
  end
  error("the script-owned editor never publishes its terminal result after exit", 0)
end

-- Moves focus to CONFIRM from any composition focus without wrapping:
-- down to the clamped bottom, then one step up.
---@param game table
function Drive.focusConfirm(game)
  for _ = 1, 5 do
    Drive.send(game, { { type = "navigate", direction = "down" } })
  end
  Drive.send(game, { { type = "navigate", direction = "up" } })
end

-- Accepts the answer confirmation, which always starts on YES for a
-- complete changed or forced draft.
---@param game table
---@param host table
function Drive.acceptAnswerPrompt(game, host)
  local status = nil
  for _ = 1, 240 do
    status = host:status()
    if status ~= nil and status.view ~= nil and status.view.level == "prompt" then
      break
    end
    game:step()
  end
  status = assert(host:status(), "the editor answers its confirmation with a prompt")
  Assert.equal(status.view.level, "prompt", "the editor confirmation reaches its prompt")
  Assert.equal(status.view.prompt.kind, "answer", "a complete draft asks its answer confirmation")
  Assert.equal(status.view.prompt.selected, "yes", "the answer confirmation starts on YES")
  Drive.send(game, { { type = "confirm" } })
end

return Drive
