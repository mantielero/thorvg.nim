float gradientStep(float edge0, float edge1, float x) 
 { 
 x = clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0); 
 return x; 
 } 
 
 float gradientStop(int index) 
 { 
 if (index >= MAX_STOP_COUNT) index = MAX_STOP_COUNT - 1; 
 int i = index / 4; 
 int j = index % 4; 
 return uGradientInfo.stopPoints[i][j]; 
 } 
 
 float gradientWrap(float d) 
 { 
 int spread = int(uGradientInfo.nStops[2]); 
 if (spread == 0) return clamp(d, 0.0, 1.0); 
 
 if (spread == 1) { 
 float n = mod(d, 2.0); 
 if (n > 1.0) { 
 n = 2.0 - n; 
 } 
 return n; 
 } 
 if (spread == 2) { 
 float n = mod(d, 1.0); 
 if (n < 0.0) { 
 n += 1.0 + n; 
 } 
 return n; 
 } 
 } 
 
 vec4 gradient(float t, float d, float l) 
 { 
 float dist = d * 2.0 / l; 
 vec4 col = vec4(0.0); 
 int i = 0; 
 int count = int(uGradientInfo.nStops[0]); 
 if (t <= gradientStop(0)) { 
 col = uGradientInfo.stopColors[0]; 
 } else if (t >= gradientStop(count - 1)) { 
 col = uGradientInfo.stopColors[count - 1]; 
 if (int(uGradientInfo.nStops[2]) == 2 && (1.0 - t) < dist) { 
 float dd = (1.0 - t) / dist; 
 float alpha = dd; 
 col *= alpha; 
 col += uGradientInfo.stopColors[0] * (1. - alpha); 
 } 
 } else { 
 for (i = 0; i < count - 1; ++i) { 
 float stopi = gradientStop(i); 
 float stopi1 = gradientStop(i + 1); 
 if (t >= stopi && t <= stopi1) { 
 col = (uGradientInfo.stopColors[i] * (1. - gradientStep(stopi, stopi1, t))); 
 col += (uGradientInfo.stopColors[i + 1] * gradientStep(stopi, stopi1, t)); 
 if (int(uGradientInfo.nStops[2]) == 2 && abs(d) > dist) { 
 if (i == 0 && (t - stopi) < dist) { 
 float dd = (t - stopi) / dist; 
 float alpha = dd; 
 col *= alpha; 
 vec4 nc = uGradientInfo.stopColors[0] * (1.0 - (t - stopi)); 
 nc += uGradientInfo.stopColors[count - 1] * (t - stopi); 
 col += nc * (1.0 - alpha); 
 } else if (i == count - 2 && (1.0 - t) < dist) { 
 float dd = (1.0 - t) / dist; 
 float alpha = dd; 
 col *= alpha; 
 col += (uGradientInfo.stopColors[0]) * (1.0 - alpha); 
 } 
 } 
 break; 
 } 
 } 
 } 
 return col; 
 } 
 
 vec3 ScreenSpaceDither(vec2 vScreenPos) 
 { 
 vec3 vDither = vec3(dot(vec2(171.0, 231.0), vScreenPos.xy)); 
 vDither.rgb = fract(vDither.rgb / vec3(103.0, 71.0, 97.0)); 
 return vDither.rgb / 255.0; 
 } 
