-- Owns the closed overlay action vocabulary for the save editor.
-- State, Layout and Renderer consume these descriptors; no parallel
-- modal action list exists. Descriptors are data only: rendering, hit
-- testing and activation share them instead of re-enumerating kinds.

---@class SaveEditorDecisionAction
---@field id string
---@field label string
---@field semantic string
---@field enabled boolean
---@field command string

local Decisions = {}

local function action(id, label, semantic, command)
  return { id = id, label = label, semantic = semantic, enabled = true, command = command }
end

---@param kind string
---@return SaveEditorDecisionAction[]
function Decisions.describe(kind)
  if kind == "bag-item" then
    return {
      action("bag:quantity", "Quantity", "secondary", "bag_quantity"),
      action("bag:remove", "Remove", "destructive", "bag_remove"),
      action("cancel", "Back", "back", "cancel"),
    }
  elseif kind == "party-move" then
    return {
      action("party-move:move", "Move", "secondary", "party-move:move"),
      action("party-move:pp", "Current PP", "secondary", "party-move:pp"),
      action("party-move:pp-ups", "PP Ups", "secondary", "party-move:pp-ups"),
      action("cancel", "Back", "back", "cancel"),
    }
  elseif kind == "remove" then
    return {
      action("remove", "Remove", "destructive", "confirm_remove"),
      action("cancel", "Back", "back", "cancel"),
    }
  elseif kind == "leave" then
    return {
      action("save", "Save & exit", "primary", "save"),
      action("discard", "Discard all", "destructive", "discard"),
      action("cancel", "Cancel", "secondary", "cancel"),
    }
  end
  error("unknown save editor decision kind " .. tostring(kind), 0)
end

return Decisions
