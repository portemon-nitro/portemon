-- Adapts the desktop NFDe dialog and Android's asynchronous document copy to
-- one app-owned picker result contract.

local NativeRomPicker = {}
local cdefApplied = false

local ANDROID_UUID = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

local UNAVAILABLE = "Native file picker is unavailable; drag and drop a .nds or .zip ROM instead."

---@class NativeRomPickerResult
---@field requestId string
---@field kind "path"|"cancel"|"error"
---@field relativePath string?
---@field displayName string?
---@field message string?

---@class AndroidRomPickerSystem: love.system
---@field openRomPicker fun(): (string|nil, string|nil)
---@field pollRomPicker fun(): NativeRomPickerResult|nil

---@class AndroidRomPickerBridge
---@field open fun(): (string|nil, string|nil)
---@field poll fun(): NativeRomPickerResult|nil

---@return AndroidRomPickerBridge|nil
local function androidBridge()
  if love.system.getOS() ~= "Android" then
    return nil
  end
  local system = love.system
  ---@cast system AndroidRomPickerSystem
  local open, poll = system.openRomPicker, system.pollRomPicker
  if type(open) ~= "function" or type(poll) ~= "function" then
    return nil
  end
  return { open = open, poll = poll }
end

local function validateUuid(requestId)
  assert(type(requestId) == "string" and requestId:match(ANDROID_UUID), "Android picker request must be a UUID")
  return requestId
end

---@param result NativeRomPickerResult
---@return NativeRomPickerResult
local function validateResult(result)
  assert(type(result) == "table", "Android picker result must be a table")
  validateUuid(result.requestId)
  if result.kind == "path" then
    assert(type(result.relativePath) == "string", "Android picker path result is malformed")
    local token, extension = result.relativePath:match("^imports/([^/]+)%.([^/]+)$")
    assert(
      type(result.displayName) == "string"
        and result.displayName ~= ""
        and result.message == nil
        and token == result.requestId
        and (extension == "nds" or extension == "zip"),
      "Android picker path result is malformed"
    )
    validateUuid(token)
  elseif result.kind == "cancel" then
    assert(
      result.relativePath == nil and result.displayName == nil and result.message == nil,
      "Android cancel is malformed"
    )
  elseif result.kind == "error" then
    assert(
      type(result.message) == "string" and result.relativePath == nil and result.displayName == nil,
      "Android picker error is malformed"
    )
  else
    error("Android picker result kind is invalid")
  end
  return result
end
local CDEF = [[
typedef char nfdu8char_t;
typedef unsigned int nfdfiltersize_t;
typedef struct {
  const nfdu8char_t *name;
  const nfdu8char_t *spec;
} nfdu8filteritem_t;
typedef enum { NFD_ERROR = 0, NFD_OKAY = 1, NFD_CANCEL = 2 } nfdresult_t;
nfdresult_t NFD_Init(void);
void NFD_Quit(void);
nfdresult_t NFD_OpenDialogU8(nfdu8char_t **outPath,
  const nfdu8filteritem_t *filterList, nfdfiltersize_t filterCount,
  const nfdu8char_t *defaultPath);
void NFD_FreePathU8(nfdu8char_t *filePath);
const nfdu8char_t *NFD_GetError(void);
]]

local function libraryPath()
  local osName = love.system.getOS()
  local osDirectory, libraryName
  if osName == "Linux" then
    osDirectory, libraryName = "linux", "libnfd.so"
  elseif osName == "Windows" then
    osDirectory, libraryName = "windows", "nfd.dll"
  elseif osName == "macOS" or osName == "OS X" then
    osDirectory, libraryName = "macos", "libnfd.dylib"
  else
    return nil
  end
  local architecture = require("ffi").arch
  if architecture ~= "x64" and architecture ~= "arm64" then
    return nil
  end
  return love.filesystem.getSourceBaseDirectory()
    .. "/app/native/"
    .. osDirectory
    .. "/"
    .. architecture
    .. "/"
    .. libraryName
end

-- Shared loader for the capability probe and the dialog: resolves the single
-- OS/architecture library truth, applies the FFI declarations once and
-- returns the loaded bridge, or nil when no usable bridge exists.
---@class NativeFilterItem one NFDe v1.3.0 name/spec filter entry
---@field name string
---@field spec string

---@class NativeFileBridge loaded NFDe v1.3.0 binding used by the probe and the dialog
---@field NFD_Init fun(): integer
---@field NFD_Quit fun()
---@field NFD_OpenDialogU8 fun(outPath: string[], filterList: NativeFilterItem[], filterCount: integer, defaultPath: string?): integer
---@field NFD_FreePathU8 fun(path: string)
---@field NFD_GetError fun(): string

---@return NativeFileBridge|nil bridge loaded native library handle
---@return string|nil declarationError FFI declaration failure detail
local function loadBridge()
  local path = libraryPath()
  if path == nil then
    return nil, nil
  end
  local ffi = require("ffi")
  if not cdefApplied then
    local declared, declarationError = pcall(ffi.cdef, CDEF)
    if not declared then
      return nil, declarationError
    end
    cdefApplied = true
  end
  local loaded, nfd = pcall(ffi.load, path)
  if not loaded then
    return nil, nil
  end
  return nfd, nil
end

-- Reports whether a native file dialog can actually open on this host. Loads
-- the same bridge the dialog uses and balances one init/quit probe without
-- opening any dialog; never mutates import state.
---@return boolean usable true only when the bridge loads and initializes
function NativeRomPicker.available()
  if love.system.getOS() == "Android" then
    return androidBridge() ~= nil
  end
  local ok, usable = pcall(function()
    local nfd = loadBridge()
    if nfd == nil then
      return false
    end
    if nfd.NFD_Init == nil or nfd.NFD_Quit == nil or nfd.NFD_OpenDialogU8 == nil then
      return false
    end
    local initialized, initResult = pcall(function()
      return nfd.NFD_Init()
    end)
    pcall(function()
      nfd.NFD_Quit()
    end)
    return initialized and initResult == 1
  end)
  return ok and usable == true
end

function NativeRomPicker.openSingle()
  if love.system.getOS() == "Android" then
    local bridge = androidBridge()
    if bridge == nil then
      return { kind = "error", message = UNAVAILABLE }
    end
    local requestId, message = bridge.open()
    if requestId == nil then
      return { kind = "error", message = tostring(message or "the previous picker operation is still finishing") }
    end
    validateUuid(requestId)
    assert(message == nil, "successful Android picker request cannot carry an error")
    return { kind = "pending", requestId = requestId }
  end
  local nfd, declarationError = loadBridge()
  if nfd == nil then
    if declarationError ~= nil then
      return { kind = "error", message = UNAVAILABLE .. " " .. tostring(declarationError) }
    end
    return { kind = "error", message = UNAVAILABLE }
  end

  local ffi = require("ffi")

  local initialized, initResult = pcall(function()
    return nfd.NFD_Init()
  end)
  if not initialized or initResult ~= 1 then
    return { kind = "error", message = UNAVAILABLE }
  end

  local result
  local outputPath = ffi.new("nfdu8char_t *[1]")
  local filters = ffi.new("nfdu8filteritem_t[2]")
  filters[0].name = "Nintendo DS ROM"
  filters[0].spec = "nds"
  filters[1].name = "ROM archive"
  filters[1].spec = "zip"
  local ok, callError = pcall(function()
    local status = nfd.NFD_OpenDialogU8(outputPath, filters, 2, nil)
    if status == 2 then
      result = { kind = "cancel" }
    elseif status == 1 and outputPath[0] ~= nil then
      result = { kind = "path", path = ffi.string(outputPath[0]) }
    else
      local detail = nfd.NFD_GetError()
      result = {
        kind = "error",
        message = UNAVAILABLE .. (detail ~= nil and (" " .. ffi.string(detail)) or ""),
      }
    end
  end)
  if outputPath[0] ~= nil then
    pcall(function()
      nfd.NFD_FreePathU8(outputPath[0])
    end)
  end
  pcall(function()
    nfd.NFD_Quit()
  end)

  if not ok then
    return { kind = "error", message = UNAVAILABLE .. " " .. tostring(callError) }
  end
  return result or { kind = "error", message = UNAVAILABLE }
end

-- Consume at most one native terminal result. Only a matching path transfers an
-- unopened stage to the caller; stale completed stages are safe to remove here.
---@param requestId string?
---@return NativeRomPickerResult?
function NativeRomPicker.poll(requestId)
  local bridge = androidBridge()
  if bridge == nil then
    return nil
  end
  if requestId ~= nil then
    validateUuid(requestId)
  end
  local result = bridge.poll()
  if result == nil then
    return nil
  end
  validateResult(result)
  if requestId == result.requestId then
    return result
  end
  if result.kind == "path" then
    local relativePath = result.relativePath
    assert(type(relativePath) == "string", "Android picker path result is malformed")
    love.filesystem.remove(relativePath)
  end
  return nil
end

return NativeRomPicker
