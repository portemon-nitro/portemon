// Private battle six-plane color/priority/window resolve, owned by
// BattlePicturePass. Main and sub engines each own their visibility,
// priority, windows, blend and brightness state; these are normalized
// semantic roles, not runtime register bits.
//
// Planes: world3d (3D BG0), window (BG1), transition (BG2),
// battlefield (BG3), objects (OBJ) and backdrop. Sub uses menu (2D BG0)
// instead of world3d; menu never takes the special 3D-alpha rule. Main
// world3d starts at priority 1; narration and healthbar OBJ use priority 0.
//
// Integer rules (six-bit channels):
// 1. Semitransparent OBJ over an eligible second plane uses the special
//    OBJ blend with native EVA/EVB; never search through an ineligible
//    second plane for a later eligible plane.
// 2. 3D BG0 over an eligible second plane uses a = alpha5 + 1, b = 32 - a,
//    channel min(63, floor((top * a + bottom * b + 16) / 32)); alpha 31
//    replaces directly. Distinct from 3D polygon-to-polygon blending and
//    from EVA/EVB.
// 3. Otherwise, when the top plane is a first target and the selected
//    window allows effects, apply the configured normal color effect:
//    alpha needs an eligible second plane and uses
//    min(63, floor((top * EVA + bottom * EVB + 8) / 16)); brighten uses
//    top + floor(((63 - top) * EVY + 8) / 16); darken uses
//    top - floor((top * EVY + 7) / 16). Coefficients clamp 0..16 and are
//    never forced to sum to 16.
// Transparent texels occupy no plane; backdrop closes the selection.
// Winning OBJ is the single native winning OBJ per pixel; lower OBJ
// fragments are never eligible second blend targets. Ties choose OBJ
// before BG and lower BG number (world/menu 0, window 1, transition 2,
// battlefield 3) first. Window order is win0, win1, OBJ window, outside.
// The host rasterizes the winning OBJ color and its per-pixel priority
// into the OBJ targets and pre-applies mosaic/scanline sampling into the
// plane canvases, so this resolve selects by priority alone. Plane
// presence is master visibility AND the selected window mask AND a
// non-transparent texel. Engine master brightness applies at its own
// stage, separately from per-plane color effects.
//
// This shader performs the 2D resolve only. Shared 3D depth/alpha stays
// in GxRenderer; indexed sampling stays in ImageSampling; pooling stays
// in ImageAssetPool.
#ifdef PIXEL
uniform Image u_planeWorld;
uniform Image u_planeWindow;
uniform Image u_planeTransition;
uniform Image u_planeBattlefield;
uniform Image u_objColor;
uniform Image u_objMeta;
uniform Image u_objWindowCoverage;
uniform vec2 u_size;
uniform vec4 u_backdrop;
uniform vec4 u_visibility;
uniform float u_objVisible;
uniform vec4 u_priorityA;
uniform vec4 u_firstTargets;
uniform vec4 u_secondTargets;
uniform vec2 u_objTargets;
uniform float u_worldIs3D;
uniform vec4 u_win0Rect;
uniform vec4 u_win1Rect;
uniform vec4 u_win0Mask;
uniform vec4 u_win1Mask;
uniform vec4 u_objWinMask;
uniform vec4 u_outsideMask;
uniform vec4 u_winObj;
uniform vec4 u_winFx;
uniform vec4 u_blendCoefficients;
uniform vec4 u_blendMode;
uniform vec2 u_brightness;
uniform float u_grayscaleBattlefield;
vec4 effect(vec4 color, Image image, vec2 texture_coords, vec2 screen_coords)
{
  vec2 uv = texture_coords;
  vec2 px = floor(uv * u_size);
  vec4 world = Texel(u_planeWorld, uv);
  vec4 window = Texel(u_planeWindow, uv);
  vec4 transition = Texel(u_planeTransition, uv);
  vec4 battlefield = Texel(u_planeBattlefield, uv);
  // Native MAIN_BG fade-buffer grayscale (battle_anim_util.c
  // PaletteToGrayscale): level = (b * 29 + r * 76 + g * 151) >> 8.
  if (u_grayscaleBattlefield > 0.5) {
    vec3 bg5 = floor(battlefield.rgb * 31.0 + 0.5);
    float level = floor((bg5.b * 29.0 + bg5.r * 76.0 + bg5.g * 151.0) / 256.0);
    battlefield.rgb = vec3(level / 31.0);
  }
  vec4 obj = Texel(u_objColor, uv);
  vec4 meta = Texel(u_objMeta, uv);
  float objWindow = Texel(u_objWindowCoverage, uv).a;
  float inWin0 = (u_win0Rect.z > 0.0 && u_win0Rect.w > 0.0
    && px.x >= u_win0Rect.x && px.y >= u_win0Rect.y
    && px.x < u_win0Rect.x + u_win0Rect.z && px.y < u_win0Rect.y + u_win0Rect.w) ? 1.0 : 0.0;
  float inWin1 = (u_win1Rect.z > 0.0 && u_win1Rect.w > 0.0
    && px.x >= u_win1Rect.x && px.y >= u_win1Rect.y
    && px.x < u_win1Rect.x + u_win1Rect.z && px.y < u_win1Rect.y + u_win1Rect.w) ? 1.0 : 0.0;
  vec4 mask;
  float objGate;
  float fxAllow;
  if (inWin0 > 0.5) {
    mask = u_win0Mask;
    objGate = u_winObj.x;
    fxAllow = u_winFx.x;
  } else if (inWin1 > 0.5) {
    mask = u_win1Mask;
    objGate = u_winObj.y;
    fxAllow = u_winFx.y;
  } else if (objWindow > 0.01) {
    mask = u_objWinMask;
    objGate = u_winObj.z;
    fxAllow = u_winFx.z;
  } else {
    mask = u_outsideMask;
    objGate = u_winObj.w;
    fxAllow = u_winFx.w;
  }
  // Transparent texels occupy no plane; each candidate carries its
  // presence explicitly so absent planes never win selection. The host
  // pre-applies mosaic/scanline sampling into plane texels.
  float presentObj = (u_objVisible > 0.5 && objGate > 0.5 && obj.a > 0.0) ? 1.0 : 0.0;
  float presentWorld = (u_visibility.x > 0.5 && mask.x > 0.5 && world.a > 0.0) ? 1.0 : 0.0;
  float presentWindow = (u_visibility.y > 0.5 && mask.y > 0.5 && window.a > 0.0) ? 1.0 : 0.0;
  float presentTransition = (u_visibility.z > 0.5 && mask.z > 0.5 && transition.a > 0.0) ? 1.0 : 0.0;
  float presentBattlefield = (u_visibility.w > 0.5 && mask.w > 0.5 && battlefield.a > 0.0) ? 1.0 : 0.0;
  // Priorities: lower value wins. Ties choose OBJ before BG and lower BG
  // number (world/menu 0, window 1, transition 2, battlefield 3) first.
  // The winning OBJ priority rides the meta green channel (priority / 3).
  float priObj = floor(meta.g * 3.0 + 0.5);
  float priWorld = u_priorityA.x;
  float priWindow = u_priorityA.y;
  float priTransition = u_priorityA.z;
  float priBattlefield = u_priorityA.w;
  float firstObj = u_objTargets.x;
  float secondObj = u_objTargets.y;
  float firstWorld = u_firstTargets.x;
  float firstWindow = u_firstTargets.y;
  float firstTransition = u_firstTargets.z;
  float firstBattlefield = u_firstTargets.w;
  float secondWorld = u_secondTargets.x;
  float secondWindow = u_secondTargets.y;
  float secondTransition = u_secondTargets.z;
  float secondBattlefield = u_secondTargets.w;
  // Top-two native plane selection over the present candidates.
  float topPri = 1e9;
  float topTie = 1e9;
  vec3 topRgb = vec3(0.0);
  float topAlpha = 0.0;
  float topIsObj = 0.0;
  float topIs3D = 0.0;
  float topObjSemi = 0.0;
  float topFirst = 0.0;
  float secondPri = 1e9;
  float secondTie = 1e9;
  vec3 secondRgb = vec3(0.0);
  float secondSecond = 0.0;
  float haveTop = 0.0;
  float haveSecond = 0.0;
  if (presentObj > 0.5) {
    topPri = priObj;
    topTie = 0.0;
    topRgb = obj.rgb;
    topAlpha = obj.a;
    topIsObj = 1.0;
    topIs3D = 0.0;
    topObjSemi = (meta.r > 0.5) ? 1.0 : 0.0;
    topFirst = firstObj;
    haveTop = 1.0;
  }
  if (presentWorld > 0.5) {
    if (haveTop < 0.5 || priWorld < topPri || (priWorld == topPri && 1.0 < topTie)) {
      if (haveTop > 0.5) {
        secondPri = topPri;
        secondTie = topTie;
        secondRgb = topRgb;
        secondSecond = (topIsObj > 0.5) ? secondObj : ((topTie == 1.0) ? secondWorld : ((topTie == 2.0) ? secondWindow : ((topTie == 3.0) ? secondTransition : secondBattlefield)));
        haveSecond = 1.0;
      }
      topPri = priWorld;
      topTie = 1.0;
      topRgb = world.rgb;
      topAlpha = world.a;
      topIsObj = 0.0;
      topIs3D = u_worldIs3D;
      topObjSemi = 0.0;
      topFirst = firstWorld;
      haveTop = 1.0;
    } else if (haveSecond < 0.5 || priWorld < secondPri || (priWorld == secondPri && 1.0 < secondTie)) {
      secondPri = priWorld;
      secondTie = 1.0;
      secondRgb = world.rgb;
      secondSecond = secondWorld;
      haveSecond = 1.0;
    }
  }
  if (presentWindow > 0.5) {
    if (haveTop < 0.5 || priWindow < topPri || (priWindow == topPri && 2.0 < topTie)) {
      if (haveTop > 0.5) {
        secondPri = topPri;
        secondTie = topTie;
        secondRgb = topRgb;
        secondSecond = (topIsObj > 0.5) ? secondObj : ((topTie == 1.0) ? secondWorld : ((topTie == 2.0) ? secondWindow : ((topTie == 3.0) ? secondTransition : secondBattlefield)));
        haveSecond = 1.0;
      }
      topPri = priWindow;
      topTie = 2.0;
      topRgb = window.rgb;
      topAlpha = window.a;
      topIsObj = 0.0;
      topIs3D = 0.0;
      topObjSemi = 0.0;
      topFirst = firstWindow;
      haveTop = 1.0;
    } else if (haveSecond < 0.5 || priWindow < secondPri || (priWindow == secondPri && 2.0 < secondTie)) {
      secondPri = priWindow;
      secondTie = 2.0;
      secondRgb = window.rgb;
      secondSecond = secondWindow;
      haveSecond = 1.0;
    }
  }
  if (presentTransition > 0.5) {
    if (haveTop < 0.5 || priTransition < topPri || (priTransition == topPri && 3.0 < topTie)) {
      if (haveTop > 0.5) {
        secondPri = topPri;
        secondTie = topTie;
        secondRgb = topRgb;
        secondSecond = (topIsObj > 0.5) ? secondObj : ((topTie == 1.0) ? secondWorld : ((topTie == 2.0) ? secondWindow : ((topTie == 3.0) ? secondTransition : secondBattlefield)));
        haveSecond = 1.0;
      }
      topPri = priTransition;
      topTie = 3.0;
      topRgb = transition.rgb;
      topAlpha = transition.a;
      topIsObj = 0.0;
      topIs3D = 0.0;
      topObjSemi = 0.0;
      topFirst = firstTransition;
      haveTop = 1.0;
    } else if (haveSecond < 0.5 || priTransition < secondPri || (priTransition == secondPri && 3.0 < secondTie)) {
      secondPri = priTransition;
      secondTie = 3.0;
      secondRgb = transition.rgb;
      secondSecond = secondTransition;
      haveSecond = 1.0;
    }
  }
  if (presentBattlefield > 0.5) {
    if (haveTop < 0.5 || priBattlefield < topPri || (priBattlefield == topPri && 4.0 < topTie)) {
      if (haveTop > 0.5) {
        secondPri = topPri;
        secondTie = topTie;
        secondRgb = topRgb;
        secondSecond = (topIsObj > 0.5) ? secondObj : ((topTie == 1.0) ? secondWorld : ((topTie == 2.0) ? secondWindow : ((topTie == 3.0) ? secondTransition : secondBattlefield)));
        haveSecond = 1.0;
      }
      topPri = priBattlefield;
      topTie = 4.0;
      topRgb = battlefield.rgb;
      topAlpha = battlefield.a;
      topIsObj = 0.0;
      topIs3D = 0.0;
      topObjSemi = 0.0;
      topFirst = firstBattlefield;
      haveTop = 1.0;
    } else if (haveSecond < 0.5 || priBattlefield < secondPri || (priBattlefield == secondPri && 4.0 < secondTie)) {
      secondPri = priBattlefield;
      secondTie = 4.0;
      secondRgb = battlefield.rgb;
      secondSecond = secondBattlefield;
      haveSecond = 1.0;
    }
  }
  float eva = clamp(u_blendCoefficients.x, 0.0, 16.0);
  float evb = clamp(u_blendCoefficients.y, 0.0, 16.0);
  float evy = clamp(u_blendCoefficients.z, 0.0, 16.0);
  vec3 c6;
  float resolved = 0.0;
  if (haveTop < 0.5) {
    c6 = floor(u_backdrop.rgb * 63.0 + 0.5);
    resolved = 1.0;
  }
  // An ineligible second plane blocks blending: never search through it
  // for a later eligible plane.
  float secondEligible = (haveSecond > 0.5 && secondSecond > 0.5) ? 1.0 : 0.0;
  vec3 b6 = floor(secondRgb * 63.0 + 0.5);
  if (resolved < 0.5 && topIsObj > 0.5 && topObjSemi > 0.5 && fxAllow > 0.5 && secondEligible > 0.5) {
    vec3 t6 = floor(topRgb * 63.0 + 0.5);
    c6 = min(floor((t6 * eva + b6 * evb + 8.0) / 16.0), vec3(63.0));
    resolved = 1.0;
  }
  if (resolved < 0.5 && topIs3D > 0.5 && topFirst > 0.5 && fxAllow > 0.5 && secondEligible > 0.5) {
    float alpha5 = floor(topAlpha * 31.0 + 0.5);
    vec3 t6 = floor(topRgb * 63.0 + 0.5);
    if (alpha5 >= 31.0) {
      c6 = t6;
    } else {
      float a = alpha5 + 1.0;
      float b = 32.0 - a;
      c6 = min(floor((t6 * a + b6 * b + 16.0) / 32.0), vec3(63.0));
    }
    resolved = 1.0;
  }
  if (resolved < 0.5 && topFirst > 0.5 && fxAllow > 0.5) {
    vec3 t6 = floor(topRgb * 63.0 + 0.5);
    if (u_blendMode.x > 0.5 && secondEligible > 0.5) {
      c6 = min(floor((t6 * eva + b6 * evb + 8.0) / 16.0), vec3(63.0));
    } else if (u_blendMode.y > 0.5) {
      c6 = t6 + floor(((63.0 - t6) * evy + 8.0) / 16.0);
    } else if (u_blendMode.z > 0.5) {
      c6 = t6 - floor((t6 * evy + 7.0) / 16.0);
    } else {
      c6 = t6;
    }
    resolved = 1.0;
  }
  if (resolved < 0.5) {
    c6 = floor(topRgb * 63.0 + 0.5);
  }
  c6 = clamp(c6, 0.0, 63.0);
  float master = clamp(u_brightness.x, 0.0, 16.0);
  if (u_brightness.y > 0.5) {
    c6 = c6 + floor(((63.0 - c6) * master + 8.0) / 16.0);
  } else if (u_brightness.y < -0.5) {
    c6 = c6 - floor((c6 * master + 7.0) / 16.0);
  }
  c6 = clamp(c6, 0.0, 63.0);
  return vec4(c6 / 63.0, 1.0);
}
#endif
