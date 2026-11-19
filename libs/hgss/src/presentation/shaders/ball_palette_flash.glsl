// Source send-out ball palette flash: BallThrow_RunThrowArc's
// BattleAnimUtil_StartPaletteBlend toward white on the ball's MAIN_OBJ
// palette. The sampled texel is the staged, palette-resolved ball cell.
// A ball with no active flash draws unshaded, so the coefficient never
// stands in for identity.

/*__portemon_shared_palette_fade__*/

#ifdef PIXEL
uniform vec3 u_target;
uniform float u_coefficient;

vec4 effect(vec4 color, Image tex, vec2 uv, vec2 screenCoords)
{
  vec4 texel = Texel(tex, uv);
  if (texel.a <= 0.0) {
    return vec4(0.0);
  }
  return vec4(portemonPaletteFade(texel.rgb, u_target, u_coefficient), texel.a) * color;
}
#endif
