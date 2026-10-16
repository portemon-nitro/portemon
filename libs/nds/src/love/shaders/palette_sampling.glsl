// One exact generated-image sampling rule shared by the map renderer and
// generated 2D draws. An indexed source resolves its index byte through the
// exact RGBA palette; anything else passes through unchanged. UVs arrive
// already transformed: wrap, mirror, and texture matrices stay caller-owned.
// Both fetches assume nearest sampling: the index byte must never
// interpolate, and the palette fetch lands on a texel center.
uniform Image u_palette;
uniform float u_paletteCount;
uniform bool u_usePalette;

vec4 resolveExactTexel(vec4 raw)
{
  if (!u_usePalette) {
    return raw;
  }
  float slot = floor(raw.r * 255.0 + 0.5);
  return Texel(u_palette, vec2((slot + 0.5) / u_paletteCount, 0.5));
}
