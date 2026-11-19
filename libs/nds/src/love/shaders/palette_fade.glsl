// One source palette blend shared by every Portemon shader that applies
// PaletteData_BeginPaletteFade-style arithmetic. The sampled channel
// quantizes to its 5-bit component, mixes with the normalized RGB555
// target using floor and clamp, then re-expands to 8-bit. Coefficients are
// the native blend units 0..16.
vec3 portemonPaletteFade(vec3 rgb, vec3 target, float coefficient)
{
  float steps = clamp(coefficient, 0.0, 16.0);
  vec3 source5 = floor(rgb * 31.0 + 0.5);
  vec3 target5 = floor(target * 31.0 + 0.5);
  vec3 blended5 = clamp(source5 + floor((target5 - source5) * steps / 16.0), 0.0, 31.0);
  return (blended5 * 8.0 + floor(blended5 / 4.0)) / 255.0;
}
