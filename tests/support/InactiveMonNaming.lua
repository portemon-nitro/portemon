-- Inactive field-test owner for the required mon naming runtime contract.
local InactiveMonNaming = {}

function InactiveMonNaming.new()
  return {
    isActive = function()
      return false
    end,
    cancelPointerCapture = function() end,
  }
end

return InactiveMonNaming
