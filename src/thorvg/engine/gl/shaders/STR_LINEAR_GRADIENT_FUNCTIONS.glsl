vec4 gradientColor(vec2 pos) 
 { 
 vec2 st = uGradientInfo.gradStartPos; 
 vec2 ed = uGradientInfo.gradEndPos; 
 vec2 ba = ed - st; 
 float d = dot(pos - st, ba) / dot(ba, ba); 
 float t = gradientWrap(d); 
 vec4 color = gradient(t, d, length(pos - st)); 
 return vec4(color.rgb * color.a, color.a); 
 } 
