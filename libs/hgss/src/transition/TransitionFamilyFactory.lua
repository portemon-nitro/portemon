-- Builds the source family selected by one staged semantic transition route.

local Overlay114Effect = require("libs.hgss.src.transition.battle.Overlay114Effect")
local Overlay115Effect = require("libs.hgss.src.transition.battle.Overlay115Effect")
local Overlay116Effect = require("libs.hgss.src.transition.battle.Overlay116Effect")
local Overlay117Effect = require("libs.hgss.src.transition.battle.Overlay117Effect")
local Overlay118Effect = require("libs.hgss.src.transition.battle.Overlay118Effect")
local Overlay119Effect = require("libs.hgss.src.transition.battle.Overlay119Effect")
local Overlay120FallbackEffect = require("libs.hgss.src.transition.battle.Overlay120FallbackEffect")
local Overlay120RedEffect = require("libs.hgss.src.transition.battle.Overlay120RedEffect")

local FALLBACK_WILD_ROLES = {
  ["plain-wild-fallback"] = true,
  ["water-wild-fallback"] = true,
  ["cave-wild-fallback"] = true,
}

local FALLBACK_TRAINER_ROLES = {
  ["plain-trainer-fallback"] = true,
  ["water-trainer-fallback"] = true,
  ["cave-trainer-fallback"] = true,
}

local TransitionFamilyFactory = {}

---@param route table<string, unknown> generated semantic transition route
---@param resources table<string, unknown> decoded staged route resources
---@param graphics table<string, function> host graphics owner for source sprites
---@param services table<string, unknown> source callback services
---@param context table<string, unknown> immutable semantic launch context
---@return table<string, function> source-family lifecycle object
function TransitionFamilyFactory.new(route, resources, graphics, services, context)
  assert(type(route) == "table", "transition family construction requires its selected route")
  assert(type(resources) == "table", "transition family construction requires its selected resources")
  assert(type(graphics) == "table", "transition family construction requires host graphics")
  assert(type(context) == "table", "transition family construction receives immutable launch context")
  local effect
  if route.role == "generic-trainer-transition" or route.role == "generic-wild-transition" then
    effect = Overlay114Effect.new(route, resources)
    effect:prepareGraphics(graphics)
  elseif
    (route.role == "trainer-transition" or route.role == "rival-transition" or route.role == "trainer-intro")
    and type(route.task) == "table"
    and (route.task.kind == "overlay115-gym-rival-intro" or route.task.kind == "overlay115-elite-intro")
  then
    effect = Overlay115Effect.new(route, resources, context, services)
    effect:prepareGraphics(graphics)
  elseif route.role == "camera-and-fade-transition" then
    effect = Overlay116Effect.new(route, assert(services, "overlay 116 requires field transition services"))
  elseif FALLBACK_WILD_ROLES[route.role] == true then
    effect = Overlay120FallbackEffect.new(route, resources, context)
  elseif FALLBACK_TRAINER_ROLES[route.role] == true then
    effect = Overlay119Effect.new(route, resources)
    effect:prepareGraphics(graphics)
  elseif route.role == "trainer-transition" and route.task == nil then
    effect = Overlay117Effect.new(route, resources)
    effect:prepareGraphics(graphics)
  elseif route.role == "background-transition" then
    effect = Overlay118Effect.new(route, resources)
  elseif route.role == "red-trainer-transition" then
    effect = Overlay120RedEffect.new(route, resources)
    effect:prepareGraphics(graphics)
  else
    error("no source family is installed for transition role " .. tostring(route.role), 2)
  end
  return effect
end

return TransitionFamilyFactory
