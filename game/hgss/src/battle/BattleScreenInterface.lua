-- Paired battle plans over the shared application layout. DualDisplay
-- puts the battlefield detail pane on the world surface and interaction
-- on auxiliary; wide pairs them side by side and tall stacks them
-- through the existing helpers at one common integer scale with no
-- synthetic gap. A pair that cannot fit at 1x reports an explicit
-- too-small plan instead of a squeezed battle, and near-square single
-- surfaces stay on a noninteractive pending plan until the compact
-- adapter lands. Battles are never outside-dismissible: presses outside
-- every control map to nothing.

local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
local LogicalSurface = require("libs.ui.src.LogicalSurface")
local NativeDisplay = require("libs.ui.src.NativeDisplay")

---@class BattleScreenInterface
local BattleScreenInterface = {}

local DETAIL_NATIVE = { id = "detail", width = NativeDisplay.WIDTH, height = NativeDisplay.HEIGHT }
local CONTENT_NATIVE = { id = "interaction", width = NativeDisplay.WIDTH, height = NativeDisplay.HEIGHT }
local INPUT_KEY = "battle"

-- Source command bounds as half-open logical regions: the lower edge
-- belongs to the lower control so adjacent controls never share one.
local COMMAND_REGIONS = {
  { id = "fight", x = 0, y = 24, w = 256, h = 120 },
  { id = "bag", x = 0, y = 144, w = 80, h = 48 },
  { id = "pokemon", x = 176, y = 144, w = 80, h = 48 },
  { id = "run", x = 88, y = 152, w = 80, h = 40 },
}

-- Source two-by-two move table with the bottom cancel strip.
local MOVE_REGIONS = {
  { id = "move:0", x = 0, y = 24, w = 128, h = 56 },
  { id = "move:1", x = 128, y = 24, w = 128, h = 56 },
  { id = "move:2", x = 0, y = 88, w = 128, h = 56 },
  { id = "move:3", x = 128, y = 88, w = 128, h = 56 },
  { id = "cancel", x = 8, y = 152, w = 240, h = 40 },
}

-- Interim target boxes around the source semantic anchors with the same
-- bottom cancel strip. Singles auto-resolve and never show these; they
-- exist so an explicit multi-target decision has admitted regions.
local TARGET_REGIONS = {
  { id = "target:0", x = 28, y = 92, w = 64, h = 48 },
  { id = "target:1", x = 164, y = 8, w = 64, h = 48 },
  { id = "target:2", x = 164, y = 92, w = 64, h = 48 },
  { id = "target:3", x = 28, y = 8, w = 64, h = 48 },
  { id = "cancel", x = 8, y = 152, w = 240, h = 40 },
}

---@param regions table<string, unknown>[] half-open logical hit regions
---@param x number logical horizontal position under test
---@param y number logical vertical position under test
---@return table<string, unknown>? hit region, nil outside every region
local function hitRegion(regions, x, y)
  for _, region in ipairs(regions) do
    local box = region --[[@as table<string, unknown>]]
    local rx = box.x --[[@as number]]
    local ry = box.y --[[@as number]]
    local rw = box.w --[[@as number]]
    local rh = box.h --[[@as number]]
    if x >= rx and x < rx + rw and y >= ry and y < ry + rh then
      return box
    end
  end
  return nil
end

---@param view table<string, unknown> internal semantic snapshot under mapping
---@return table<string, unknown>? active hit regions, nil while no layout owns input
local function regionsFor(view)
  local mode = view.mode
  if mode == "command" then
    return COMMAND_REGIONS
  elseif mode == "moves" then
    return MOVE_REGIONS
  elseif mode == "target" then
    return TARGET_REGIONS
  end
  return nil
end

---@param view table<string, unknown>
---@return string layout scope behind the current mode
local function scopeFor(view)
  local mode = view.mode
  if mode == "moves" then
    return "moves"
  elseif mode == "target" then
    return "target"
  end
  return "command"
end

---@param event table<string, unknown> session-inverted logical input
---@param view table<string, unknown> internal semantic snapshot carrying the mode scope
---@param regions table<string, unknown>[] active hit regions
---@return table<string, unknown>? semantic battle input, nil when the battle ignores it
local function mapPointer(event, view, regions)
  local eventType = event.type
  if eventType == "pointer_down" and event.outside == true then
    return nil
  end
  if eventType == "pointer_down" and type(event.x) == "number" and type(event.y) == "number" then
    local region = hitRegion(regions, event.x --[[@as number]], event.y --[[@as number]])
    if region == nil then
      return nil
    end
    return { type = "battle_press", control = { scope = scopeFor(view), id = region.id }, pointerId = event.pointerId }
  end
  if eventType == "pointer_move" and type(event.x) == "number" and type(event.y) == "number" then
    local region = hitRegion(regions, event.x --[[@as number]], event.y --[[@as number]])
    local control = nil
    if region ~= nil then
      control = { scope = scopeFor(view), id = region.id }
    end
    return { type = "battle_slide", control = control, pointerId = event.pointerId }
  end
  if eventType == "pointer_up" and type(event.x) == "number" and type(event.y) == "number" then
    local region = hitRegion(regions, event.x --[[@as number]], event.y --[[@as number]])
    local control = nil
    if region ~= nil then
      control = { scope = scopeFor(view), id = region.id }
    end
    return { type = "battle_activate", control = control, pointerId = event.pointerId }
  end
  if eventType == "pointer_cancel" then
    return { type = "pointer_cancel", pointerId = event.pointerId }
  end
  if eventType == "confirm" or eventType == "cancel" then
    return { type = eventType }
  end
  if eventType == "navigate" then
    return { type = "navigate", direction = event.direction, pointerId = event.pointerId }
  end
  return nil
end

---@param event table<string, unknown> session-inverted logical input
---@param view table<string, unknown> internal semantic snapshot
---@param plan ApplicationPlan resolved plan carrying the canonical content
---@return table<string, unknown>? semantic battle input, nil when the battle ignores it
local function mapBattleInput(event, view, plan)
  local content = plan.content --[[@as table<string, unknown>]]
  if content.tooSmall == true or content.pendingAdapter == true then
    return nil
  end
  local regions = regionsFor(view)
  if regions == nil then
    if event.type == "pointer_cancel" then
      return { type = "pointer_cancel", pointerId = event.pointerId }
    end
    return nil
  end
  return mapPointer(event, view, regions)
end

---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> internal semantic snapshot
---@param plan ApplicationPlan
local function renderBattle(resources, view, plan)
  local BattleRenderer = require("game.hgss.src.battle.BattleRenderer")
  local graphics = assert(resources.graphics, "the battle render borrows its host graphics")
  local panes = assert(plan.panes, "the battle plan carries its panes")
  for _, pane in ipairs(panes) do
    local placement = assert(pane.placement, "battle panes carry placements")
    LogicalSurface.draw(graphics, placement, function()
      BattleRenderer.drawPane(resources, view, pane.id --[[@as string]], plan.content)
    end)
  end
end

---@return nil
local function noopRender(_, _, _) end

---@return nil
local function noopMap(_, _, _)
  return nil
end

---@param kind table<string, unknown> canonical content marking the inactive reason
---@return ApplicationPlan valid inactive plan: no panes, no targets, cancellation still deliverable
local function inactivePlan(kind)
  return {
    panes = {},
    frames = {},
    content = kind,
    inputKey = INPUT_KEY .. "-inactive",
    render = noopRender,
    mapInput = noopMap,
  }
end

---@param mode string controller mode under resolution
---@param requestId integer? open request identity under resolution
---@param signature string? measurement signature under resolution
---@return string stable input-geometry identity for the semantic state
local function inputKey(mode, requestId, signature)
  return table.concat({ INPUT_KEY, mode, tostring(requestId or 0), tostring(signature or "-") }, ":")
end

-- Binds no manifest: battle regions are fixed source geometry and the
-- per-case override replaces whole render/input pairs through the
-- session. Returns the default resolver set.
---@return table<string, fun(context: ApplicationLayout.Context, view: table<string, unknown>): ApplicationPlan>
function BattleScreenInterface.defaults()
  ---@param panes table[] resolved panes
  ---@param frames table[] resolved outer frames
  ---@param view table<string, unknown> internal semantic snapshot
  ---@param signature string? measurement signature
  ---@return ApplicationPlan
  local function battlePlan(panes, frames, view, signature)
    return {
      panes = panes,
      frames = frames,
      content = { kind = "battle", layout = scopeFor(view), armed = view.armed },
      inputKey = inputKey(view.mode --[[@as string]], view.requestId --[[@as integer]], signature),
      render = renderBattle,
      mapInput = mapBattleInput,
    }
  end

  ---@param context ApplicationLayout.Context
  ---@param view table<string, unknown>
  ---@param horizontal boolean true for side-by-side pairs, false for stacked pairs
  ---@return ApplicationPlan
  local function paired(context, view, horizontal)
    local geometry
    if horizontal then
      geometry = ApplicationLayout.sideBySide(context, DETAIL_NATIVE, CONTENT_NATIVE)
    else
      geometry = ApplicationLayout.stacked(context, DETAIL_NATIVE, CONTENT_NATIVE)
    end
    -- Below 1x the battle reports too-small instead of falling back:
    -- the compact adapter owns the fallback, not this resolver.
    if geometry == nil then
      return inactivePlan({ kind = "battle", tooSmall = true })
    end
    local detail = geometry.placements[DETAIL_NATIVE.id]
    local interaction = geometry.placements[CONTENT_NATIVE.id]
    if detail == nil or interaction == nil then
      return inactivePlan({ kind = "battle", tooSmall = true })
    end
    return battlePlan({
      { id = DETAIL_NATIVE.id, placement = detail, interactive = false },
      { id = CONTENT_NATIVE.id, placement = interaction, interactive = true },
    }, geometry.frames or {}, view, context.measurement.signature)
  end

  ---@param context ApplicationLayout.Context
  ---@param view table<string, unknown>
  ---@return ApplicationPlan
  local function dualDisplay(context, view)
    local geometry = ApplicationLayout.nativeDual(context, DETAIL_NATIVE, CONTENT_NATIVE, {})
    local detail = geometry.placements[DETAIL_NATIVE.id]
    local interaction = geometry.placements[CONTENT_NATIVE.id]
    if detail == nil or interaction == nil then
      return inactivePlan({ kind = "battle", tooSmall = true })
    end
    return battlePlan({
      { id = DETAIL_NATIVE.id, placement = detail, interactive = false },
      { id = CONTENT_NATIVE.id, placement = interaction, interactive = true },
    }, geometry.frames or {}, view, context.measurement.signature)
  end

  ---@param context ApplicationLayout.Context
  ---@param view table<string, unknown>
  ---@return ApplicationPlan
  local function nativeLike(context, view)
    -- Single-surface native-like stays noninteractive until the compact
    -- adapter lands: a pending plan, never a falsely completed battle UI.
    local _ = context
    local _ = view
    local plan = inactivePlan({ kind = "battle", pendingAdapter = true })
    plan.mapInput = mapBattleInput
    return plan
  end

  ---@param context ApplicationLayout.Context
  ---@param view table<string, unknown>
  ---@return ApplicationPlan
  local function wideCase(context, view)
    return paired(context, view, true)
  end

  ---@param context ApplicationLayout.Context
  ---@param view table<string, unknown>
  ---@return ApplicationPlan
  local function tallCase(context, view)
    return paired(context, view, false)
  end

  return {
    dualDisplay = dualDisplay,
    nativeLike = nativeLike,
    wide = wideCase,
    tall = tallCase,
  }
end

return BattleScreenInterface
