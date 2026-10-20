-- Loads the app-owned NFDe desktop bridge and returns one copied path.

local NativeRomPicker = {}
local cdefApplied = false

local UNAVAILABLE = "Native file picker is unavailable; drag and drop a .nds or .zip ROM instead."
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

function NativeRomPicker.openSingle()
  local path = libraryPath()
  if path == nil then
    return { kind = "error", message = UNAVAILABLE }
  end

  local ffi = require("ffi")
  if not cdefApplied then
    local declared, declarationError = pcall(ffi.cdef, CDEF)
    if not declared then
      return { kind = "error", message = UNAVAILABLE .. " " .. tostring(declarationError) }
    end
    cdefApplied = true
  end
  local loaded, nfd = pcall(ffi.load, path)
  if not loaded then
    return { kind = "error", message = UNAVAILABLE }
  end

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

return NativeRomPicker
