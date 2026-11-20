// Animation sprite copy palette blend. Managed copies carry their own
// MAIN_OBJ palette, so the source blend that BattlerPaletteFade applies
// toward an RGB555 target runs on the copy's exact sampled texels. The
// shared sampling rule resolves indexed portrait pages first, and the
// shared blend snippet evaluates the native 5-bit floor/clamp arithmetic
// with coefficients in 0..16. Alpha passes through untouched.

/*__portemon_shared_image_sampling__*/
/*__portemon_shared_palette_fade__*/

#ifdef PIXEL
uniform vec3 u_fadeTarget;
uniform float u_fadeCoefficient;

vec4 effect(vec4 tint, Image tex, vec2 uv, vec2 screenCoords)
{
  vec4 texel = resolveExactTexel(Texel(tex, uv));
  if (texel.a <= 0.0) {
    return vec4(0.0);
  }
  if (u_fadeCoefficient > 0.0) {
    texel.rgb = portemonPaletteFade(texel.rgb, u_fadeTarget, u_fadeCoefficient);
  }
  return texel * tint;
}
#endif
