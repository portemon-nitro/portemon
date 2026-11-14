-- Strict persisted state for the retail SysInfo mystery-gift flag. The
-- source SysInfo block carries machine identity (RTC, MAC, profile id)
-- the product never persists; only the mystery-gift active bit scripts
-- touch rides here. The bucket carries exactly its schema and the
-- boolean, rejects malformed records without repairing them, and
-- round-trips through capture/restore. Pure domain code.

local Errors = require("libs.errors.src.Errors")
local GameSaveErrors = require("libs.hgss.src.save.GameSaveErrors")

---@class SysInfoState
---@field private _active boolean
local SysInfoState = {}
SysInfoState.__index = SysInfoState

SysInfoState.SCHEMA = "hgss-sys-info-v1"

---@return table<string, unknown>
function SysInfoState.empty()
  return { schema = SysInfoState.SCHEMA, mysteryGiftActive = false }
end

---@param record unknown
local function checkRecord(record)
  if type(record) ~= "table" then
    Errors.raise(GameSaveErrors.GAME_SAVE_BUCKET_INVALID, "sysInfo bucket must be a record", { bucket = "sysInfo" })
  end
  assert(type(record) == "table")
  if record.schema ~= SysInfoState.SCHEMA then
    Errors.raise(GameSaveErrors.GAME_SAVE_BUCKET_INVALID, "sysInfo schema is invalid", { bucket = "sysInfo" })
  end
  if type(record.mysteryGiftActive) ~= "boolean" then
    Errors.raise(
      GameSaveErrors.GAME_SAVE_BUCKET_INVALID,
      "sysInfo mystery-gift flag must be a boolean",
      { bucket = "sysInfo" }
    )
  end
  for key in pairs(record) do
    if key ~= "schema" and key ~= "mysteryGiftActive" then
      Errors.raise(GameSaveErrors.GAME_SAVE_BUCKET_INVALID, "sysInfo bucket has an unknown field", {
        bucket = "sysInfo",
        field = key,
      })
    end
  end
end

---@param record table<string, unknown>
---@return SysInfoState
function SysInfoState.new(record)
  checkRecord(record)
  assert(type(record) == "table" and type(record.mysteryGiftActive) == "boolean")
  return setmetatable({ _active = record.mysteryGiftActive }, SysInfoState)
end

---@return boolean
function SysInfoState:isMysteryGiftActive()
  return self._active == true
end

-- Retail ScrCmd_SetMysteryGiftActive has no operand and no clear
-- counterpart: the flag only ever turns on.
function SysInfoState:setMysteryGiftActive()
  self._active = true
end

---@return table<string, unknown>
function SysInfoState:capture()
  return { schema = SysInfoState.SCHEMA, mysteryGiftActive = self._active == true }
end

return SysInfoState
