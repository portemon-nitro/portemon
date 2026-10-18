extern Image sceneImage;
extern Image previousImage;
extern vec4 sourceRect;
extern bool hasPrevious;
extern float historyWeight;

vec4 effect(vec4 color, Image texture, vec2 textureCoords, vec2 screenCoords) {
  vec4 current = Texel(sceneImage, textureCoords);
  if (!hasPrevious) {
    return current;
  }
  vec2 previousCoords = (textureCoords - sourceRect.xy) / sourceRect.zw;
  vec4 previous = Texel(previousImage, previousCoords);
  return vec4(current.rgb * (1.0 - historyWeight) + previous.rgb * historyWeight, current.a);
}
