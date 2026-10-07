// Source picture palette operation for the native Summary picture. The
// compiled picture samples carry an optional normalized blend: a 5-bit
// target triple plus an integer coefficient in 0..16. The blend evaluates
// with source integer semantics below: the sampled channel is quantized
// to its 5-bit component, mixed against the target with a floor and a
// clamp, then re-expanded. Alpha (including index-zero transparency)
// passes through untouched. The caller draws a no-op blend (coefficient
// 0) as its plain unshaded frame, so the quantized round trip below never
// stands in for identity.

#ifdef PIXEL
uniform vec3 u_target;
uniform float u_coefficient;

vec4 effect(vec4 tint, Image tex, vec2 uv, vec2 screenCoords)
{
  vec4 texel = Texel(tex, uv);

  if (texel.a < 0.5) {
    return vec4(0.0);
  }

  float steps = clamp(u_coefficient, 0.0, 16.0);
  vec3 source5 = floor(texel.rgb * 31.0 + 0.5);
  vec3 mixed5 = clamp(floor((source5 * (16.0 - steps) + u_target * steps) / 16.0), 0.0, 31.0);

  return vec4(mixed5 / 31.0, texel.a) * tint;
}
#endif
