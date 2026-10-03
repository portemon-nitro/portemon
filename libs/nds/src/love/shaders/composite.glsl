// DS translucent compositor. A full-screen pass that applies the exact
// integer DS blend/state equations to one accepted source-fragment buffer
// (map.glsl's sourceColor/sourceMeta) against the active color and compact
// translucent state, writing the result into the inactive destination pair
// (the ping-pong halves of the compositor loop in GxRenderer:draw). The
// destination is never sampled and written in the same pass: the composite
// reads the active pair and writes the inactive one, then the renderer swaps
// which pair is active.
//
// The modeled DS contract (melonDS GPU3D_Soft.cpp AlphaBlend /
// PlotTranslucentPixel, HGSS field alpha blending):
//   1. a fragment already rejected by the source pass never reaches here
//      (sourceMeta.r == 0 -> the destination is copied unchanged);
//   2. dstAlpha5 == 0 -> the accepted source replaces the destination
//      color/alpha;
//   3. otherwise, with w = srcAlpha5 + 1 (1..31), each RGB6 channel is
//      out = ((src * w) + (dst * (32 - w))) >> 5;
//   4. output alpha5 = max(srcAlpha5, dstAlpha5);
//   5. opaque polygon ID and DS Z depth remain in immutable renderState;
//   6. the new fog gate B = prior effective fog gate AND source fog flag;
//   7. the new last-translucent-ID A = the accepted source polygon ID,
//      encoded (id + 1) / 64 (0 = none).
//
// All RGB math is integer RGB6 (0..63) and alpha is integer alpha5 (0..31);
// conversion back to normalized framebuffer values happens only after the
// integer arithmetic. The composite draw uses replace semantics -- no second
// host alpha blend is applied to already-computed output.

#ifdef PIXEL
uniform Image u_sourceColor;
uniform Image u_sourceMeta;
uniform Image u_activeColor;
uniform Image u_opaqueState;
uniform Image u_activeTranslucentState;
uniform vec2 u_size;

// Decode the source polygon ID from sourceMeta.a ((id + 1) / 64). The
// encoding is chosen so all 6-bit IDs survive normalized rgba8 storage.
int sourceId(vec4 meta)
{
  return int(floor(meta.a * 64.0 + 0.5)) - 1;
}

void effect()
{
  vec2 uv = gl_FragCoord.xy / u_size;
  vec4 meta = Texel(u_sourceMeta, uv);
  vec4 dstColor = Texel(u_activeColor, uv);
  vec4 dstTranslucentState = Texel(u_activeTranslucentState, uv);
  vec4 opaqueState = Texel(u_opaqueState, uv);

  vec4 outColor = dstColor;
  vec4 outTranslucentState = dstTranslucentState;

  if (meta.r > 0.5) {
    vec4 srcColor = Texel(u_sourceColor, uv);
    int srcA5 = int(floor(srcColor.a * 31.0 + 0.5));
    int dstA5 = int(floor(dstColor.a * 31.0 + 0.5));
    int srcId = sourceId(meta);

    if (dstA5 == 0) {
      // Accepted source replaces the destination color/alpha outright.
      outColor = srcColor;
    } else {
      // DS integer blend: w = srcA5 + 1 (1..31), each channel
      // out = ((src * w) + (dst * (32 - w))) >> 5, in RGB6.
      int w = srcA5 + 1;
      vec3 src6 = floor(srcColor.rgb * 63.0 + 0.5);
      vec3 dst6 = floor(dstColor.rgb * 63.0 + 0.5);
      vec3 out6 = floor((src6 * float(w) + dst6 * float(32 - w)) / 32.0);
      outColor.rgb = out6 / 63.0;
      outColor.a = float(max(srcA5, dstA5)) / 31.0;
    }

    // A=0 means this is the first accepted translucent item over this pixel;
    // start its fog chain from the immutable opaque owner's gate.
    float previousFog = dstTranslucentState.a > 0.0 ? dstTranslucentState.b : opaqueState.b;
    outTranslucentState = vec4(0.0, 0.0, previousFog > 0.5 && meta.b > 0.5 ? 1.0 : 0.0, float(srcId + 1) / 64.0);
  }

  love_Canvases[0] = outColor;
  love_Canvases[1] = outTranslucentState;
}
#endif
