-- The shared product skin owns the concrete menu appearance, not its resources.

local Assert = require("tests.support.Assert")
local FakeGraphics = require("tests.support.FakeGraphics")
local MainMenuRenderer = require("app.src.mainmenu.MainMenuRenderer")
local ProductMenuSkin = require("app.src.ui.ProductMenuSkin")

local T = { tests = {} }

function T.tests.version_skins_are_owned_and_match_the_existing_menu_backgrounds()
  for _, versionId in ipairs({ "heartgold", "soulsilver" }) do
    local first = ProductMenuSkin.forVersion(versionId)
    local second = ProductMenuSkin.forVersion(versionId)
    local menu = MainMenuRenderer.new({
      text = { drawTextWithPalette = function() end },
      versionId = versionId,
    })

    Assert.isTrue(first ~= second, "each renderer gets its own appearance record")
    Assert.deepEqual(first.background, menu.background, "skin preserves the selected Main Menu background")
    Assert.isTrue(first.background ~= second.background, "background values are not shared between renderers")
    Assert.isTrue(first.cards.normal.face ~= second.cards.normal.face, "card colors are not shared between renderers")

    first.background[1] = 0
    first.cards.normal.face[1] = 0
    Assert.deepEqual(second.background, menu.background, "one renderer cannot recolor another renderer's background")
    Assert.equal(second.cards.normal.face[1], 0xFB / 255, "one renderer cannot recolor another renderer's cards")
  end

  local ok = pcall(ProductMenuSkin.forVersion, "unsupported")
  Assert.isFalse(ok, "unknown game identities do not receive a default skin")
end

function T.tests.card_variants_focus_and_disabled_roles_draw_through_image_button()
  local skin = ProductMenuSkin.forVersion("heartgold")
  local rect = { x = 4, y = 8, width = 80, height = 32 }
  for _, variant in ipairs({ "normal", "inset", "overflow" }) do
    local graphics = FakeGraphics.new()
    ProductMenuSkin.drawCard(graphics, skin, rect, variant, false, false)
    Assert.isTrue(#graphics.rectangles > 0, variant .. " card variant draws its chrome")
  end

  local focusedGraphics = FakeGraphics.new()
  ProductMenuSkin.drawCard(focusedGraphics, skin, rect, "normal", true, false)
  Assert.deepEqual(
    focusedGraphics.rectangles[2].color,
    skin.cards.normal.selectedRim,
    "focused cards retain the Main Menu selection rim"
  )

  local disabledGraphics = FakeGraphics.new()
  ProductMenuSkin.drawCard(disabledGraphics, skin, rect, "normal", false, true)
  Assert.deepEqual(
    disabledGraphics.rectangles[2].color,
    skin.cards.disabled.normal.rim,
    "disabled cards use an explicit readable card role"
  )
end

function T.tests.text_roles_delegate_to_the_generated_font_palette_renderer()
  local skin = ProductMenuSkin.forVersion("soulsilver")
  local graphics = FakeGraphics.new()
  local calls = {}
  local text = {
    drawTextWithPalette = function(_, value, x, y, palette)
      calls[#calls + 1] = { value = value, x = x, y = y, palette = palette }
    end,
  }

  for _, role in ipairs({ "normal", "information", "hint", "error" }) do
    ProductMenuSkin.drawText(graphics, text, skin, role, "VALUE", 12, 18)
  end
  Assert.equal(#calls, 4, "each text role is sent through FieldTextRenderer palette drawing")
  Assert.equal(calls[2].palette, skin.text.information, "information uses its role palette")
  Assert.equal(calls[4].palette, skin.text.error, "errors use their role palette")
  Assert.isTrue(calls[3].palette.foreground.r > 0, "hint text remains legible")
  Assert.deepEqual({ graphics.getColor() }, { 1, 1, 1, 1 }, "palette drawing restores the white tint")

  local ok = pcall(ProductMenuSkin.drawText, graphics, text, skin, "unknown", "VALUE", 0, 0)
  Assert.isFalse(ok, "unknown text roles are rejected")
end

return T
