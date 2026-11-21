vec4 gradientColor(vec2 pos) 
 { 
 float width = fwidth(pos.y); 
 vec4 color; 
 if (pos.x >= 0.0 && abs(pos.y) < 0.5 * width) { 
 int count = int(uGradientInfo.nStops[0]); 
 float coverage = pos.y / width + 0.5; 
 vec4 first = uGradientInfo.stopColors[0]; 
 vec4 last = uGradientInfo.stopColors[count - 1]; 
 return mix(vec4(last.rgb * last.a, last.a), vec4(first.rgb * first.a, first.a), coverage); 
 } else { 
 const float INV_TWO_PI = 0.15915494309189535; 
 float t = fract(atan(pos.y, pos.x) * INV_TWO_PI); 
 color = gradient(t, 0.0, 1.0); 
 } 
 return vec4(color.rgb * color.a, color.a); 
 } 
