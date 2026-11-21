-- CPU-only entry point for the presentation preparation worker. Decodes the
-- resident payload the main thread resolved for one request: mesh upload
-- buffers, image data, or private image derivatives, replying with flat
-- records carrying love Data/ImageData. The payload crosses as its own
-- immutable Data reference, so this state opens no generated file. Never
-- touches love.graphics: GPU realization stays on the main thread.
--
-- The module is resolved through the packaged require path by a small
-- literal bootstrap: the queue starts its thread from that bootstrap, which
-- installs the explicitly supplied development search path when required
-- and then calls run with the queue's channel pair. Requiring this module
-- in any other state only exposes run without starting any work.

local Worker = {}

---@param requestChannel table<string, unknown> borrowed queue request channel
---@param replyChannel table<string, unknown> borrowed queue reply channel
function Worker.run(requestChannel, replyChannel)
  assert(requestChannel and replyChannel, "preparation worker requires its request/reply channels")

  pcall(require, "love.image")

  local Errors = require("libs.errors.src.Errors")
  local ImageDerivative = require("libs.hgss.src.presentation.ImageDerivative")
  local NativeTextureBank = require("libs.assets.src.model.NativeTextureBank")
  local SceneMesh = require("libs.hgss.src.presentation.SceneMesh")
  local TextureDecoder = require("libs.nds.src.gx.TextureDecoder")

  ---@param payload unknown
  ---@return love.Data
  local function payloadData(payload)
    assert(
      type(payload) == "userdata" and type(payload.getString) == "function",
      "preparation worker requires its resident payload"
    )
    return payload --[[@as love.Data]]
  end

  local function fail(token, kind, path, cause)
    local text = Errors.is(cause) and Errors.format(cause) or tostring(cause)
    replyChannel:push({ token = token, ok = false, kind = kind, path = path, error = text })
  end

  -- One decoder scratch for every serial texture job: decodeInto resizes and
  -- rewrites the palette storage it needs, so successive jobs can share it.
  local textureScratch = TextureDecoder.newScratch()

  -- One parsed native texture bank, keyed by its versioned logical path. The
  -- queue identifies texture work by bank file plus selected names, so several
  -- selections of one bank arrive as separate jobs; they reuse this parse
  -- instead of reading and parsing the whole bank again. A different path
  -- replaces the entry, so the worker holds at most one parsed bank. Generated
  -- banks are content-addressed, so a path's bytes are stable for one worker
  -- lifetime. Never persisted and never accompanied by a derivative.
  local parsedBankPath = nil
  local parsedBank = nil
  ---@param data love.Data
  ---@param logicalPath string
  ---@return NativeTextureBank.Bank
  local function nativeBankFor(data, logicalPath)
    if parsedBankPath == logicalPath then
      return parsedBank --[[@as NativeTextureBank.Bank]]
    end
    local bank, bankError = NativeTextureBank.read(data:getString())
    if bank == nil then
      error(bankError, 0)
    end
    parsedBankPath = logicalPath
    parsedBank = bank
    return bank
  end

  local function prepareMesh(token, data, path)
    local ok, prepared = pcall(SceneMesh.prepareUpload, payloadData(data):getString(), path)
    if not ok then
      fail(token, "mesh", path, prepared)
      return
    end
    replyChannel:push({
      token = token,
      ok = true,
      kind = "mesh",
      path = path,
      vertexData = prepared.vertexData,
      indexData = prepared.indexData,
      vertexCount = prepared.vertexCount,
      indexCount = prepared.indexCount,
      indexType = prepared.indexType,
      centerX = prepared.centerX,
      centerY = prepared.centerY,
      centerZ = prepared.centerZ,
      minX = prepared.minX,
      maxX = prepared.maxX,
      minY = prepared.minY,
      maxY = prepared.maxY,
      minZ = prepared.minZ,
      maxZ = prepared.maxZ,
    })
  end

  -- A generated PNG is the only persistent image asset: it is decoded here,
  -- classified into the padded/indexed upload payload, and never copied into a
  -- second on-disk derivative. Replies carry only Data plus small metadata; a
  -- missing or damaged generated PNG fails loudly instead of substituting
  -- bytes. Never touches graphics.
  local function prepareImageDerivative(token, data, path)
    local function work()
      local imageData, imageError = love.image.newImageData(payloadData(data) --[[@as love.FileData]])
      if imageData == nil then
        error("unreadable image source: " .. tostring(path) .. ": " .. tostring(imageError), 0)
      end
      local classified = ImageDerivative.classify(imageData)
      replyChannel:push({
        token = token,
        ok = true,
        kind = "image-derivative",
        path = path,
        pixelHash = classified.pixelHash,
        width = classified.width,
        height = classified.height,
        representation = classified.kind,
        colors = classified.colors,
        indexData = classified.indexData,
        paletteData = classified.paletteData,
      })
    end
    local ok, err = pcall(work)
    if not ok then
      fail(token, "image-derivative", path, err)
    end
  end

  -- One whole native model bank, decoded and packed for upload: every draw of
  -- the bank replays once (transform-preserving draws replay each shared
  -- command stream once and fan their pose segments out), the bank's terrain
  -- group is repaired once, and one upload packet per draw comes back. The
  -- main thread then only realizes the draws the scene actually selects. No
  -- ROM source and no GPU object.
  local function prepareNativeBank(token, data, path)
    local function work()
      return SceneMesh.prepareNativeBank(payloadData(data):getString(), path)
    end
    local ok, prepared = pcall(work)
    if not ok then
      fail(token, "g4gx", path, prepared)
      return
    end
    replyChannel:push({
      token = token,
      ok = true,
      kind = "g4gx",
      path = path,
      draws = prepared.draws,
    })
  end

  -- One named texture/palette pair of a native texture bank: the compact
  -- source texels decode straight to RGBA in this worker, then classify into
  -- the same upload payload the PNG path produces. The palette is selected by
  -- name, never baked into the perspective of one material. The decoded RGBA
  -- bytes go to the classifier as the ByteData the decoder filled, so no
  -- intermediate ImageData is created.
  local function prepareNativeTexture(token, data, logicalPath, path, selector)
    local function work()
      assert(
        type(selector) == "table" and type(selector.textureName) == "string",
        "native texture preparation requires a named texture"
      )
      local bank = nativeBankFor(data, logicalPath)
      local texture = bank:texture(selector.textureName)
      if texture == nil then
        error("texture bank has no texture " .. tostring(selector.textureName) .. ": " .. tostring(path), 0)
      end
      local palette = nil
      if selector.paletteName ~= nil then
        palette = bank:palette(selector.paletteName)
        if palette == nil then
          error("texture bank has no palette " .. tostring(selector.paletteName) .. ": " .. tostring(path), 0)
        end
      end
      local opts = {
        format = texture.formatRaw,
        width = texture.width,
        height = texture.height,
        color0Transparent = texture.color0Transparent,
        texel = texture.texels,
        palette = palette and palette.data or "",
      }
      if texture.indexData ~= nil then
        opts.indexData = texture.indexData
      end
      local rgba = love.data.newByteData(texture.width * texture.height * 4)
      local rgbaSize = rgba:getSize()
      ---@cast rgbaSize integer
      TextureDecoder.decodeInto(opts, rgba:getFFIPointer(), rgbaSize, textureScratch, {
        name = texture.name,
      })
      return ImageDerivative.classifyPixels(texture.width, texture.height, rgba)
    end
    local ok, classified = pcall(work)
    if not ok then
      fail(token, "g4tx", path, classified)
      return
    end
    replyChannel:push({
      token = token,
      ok = true,
      kind = "image-derivative",
      path = path,
      pixelHash = classified.pixelHash,
      width = classified.width,
      height = classified.height,
      representation = classified.kind,
      colors = classified.colors,
      indexData = classified.indexData,
      paletteData = classified.paletteData,
    })
  end

  -- Sample payloads travel as one transferable ByteData built from the
  -- resident PCM16LE bytes, without assembling Lua sample tables and
  -- without touching graphics.
  local function prepareAudioSample(token, data, path)
    local function work()
      local bytes = payloadData(data):getString()
      if #bytes == 0 or #bytes % 2 ~= 0 then
        error("unreadable audio sample payload: " .. tostring(path), 0)
      end
      local byteData = love.data.newByteData(bytes)
      replyChannel:push({
        token = token,
        ok = true,
        kind = "audio-sample",
        path = path,
        byteData = byteData,
        size = #bytes,
      })
    end
    local ok, err = pcall(work)
    if not ok then
      fail(token, "audio-sample", path, err)
    end
  end

  -- Plain images decode from the same resident payload reference as every
  -- other job kind, so the PNG decode and the reply shape stay exactly as
  -- before.
  local function prepareImage(token, data, path)
    local function work()
      local imageData, imageError = love.image.newImageData(payloadData(data) --[[@as love.FileData]])
      if imageData == nil then
        error("unreadable image source: " .. tostring(path) .. ": " .. tostring(imageError), 0)
      end
      return imageData
    end
    local ok, imageData = pcall(work)
    if not ok then
      fail(token, "image", path, imageData)
      return
    end
    replyChannel:push({ token = token, ok = true, kind = "image", path = path, imageData = imageData })
  end

  while true do
    local job = requestChannel:demand()
    if type(job) ~= "table" or job.op == "shutdown" then
      break
    end
    if job.op == "prepare" and job.kind == "mesh" then
      local ok, err = pcall(prepareMesh, job.token, job.data, job.path)
      if not ok then
        fail(job.token, job.kind, job.path, err)
      end
    elseif job.op == "prepare" and job.kind == "image" then
      local ok, err = pcall(prepareImage, job.token, job.data, job.path)
      if not ok then
        fail(job.token, job.kind, job.path, err)
      end
    elseif job.op == "prepare" and job.kind == "image-derivative" then
      local ok, err = pcall(prepareImageDerivative, job.token, job.data, job.path)
      if not ok then
        fail(job.token, job.kind, job.path, err)
      end
    elseif job.op == "prepare" and job.kind == "g4gx" then
      local ok, err = pcall(prepareNativeBank, job.token, job.data, job.path)
      if not ok then
        fail(job.token, job.kind, job.path, err)
      end
    elseif job.op == "prepare" and job.kind == "g4tx" then
      local ok, err = pcall(prepareNativeTexture, job.token, job.data, job.logicalPath, job.path, job.selector)
      if not ok then
        fail(job.token, job.kind, job.path, err)
      end
    elseif job.op == "prepare" and job.kind == "audio-sample" then
      local ok, err = pcall(prepareAudioSample, job.token, job.data, job.path)
      if not ok then
        fail(job.token, job.kind, job.path, err)
      end
    else
      fail(job.token, job.kind, job.path, "unknown preparation request")
    end
  end
end

-- A directly started thread entry carries its channels as chunk arguments;
-- a plain require carries the module name instead and only exposes run.
local directRequest, directReply = ...
if type(directRequest) == "table" and type(directReply) == "table" then
  Worker.run(directRequest, directReply)
end

return Worker
