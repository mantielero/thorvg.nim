uniform sampler2D uSrcTexture; 
 uniform sampler2D uMaskTexture; 
 in vec2 vUV; 
 out vec4 FragColor; 
 
 void main() 
 { 
 vec4 srcColor = texture(uSrcTexture, vUV); 
 vec4 maskColor = texture(uMaskTexture, vUV); 
 float a = srcColor.a - maskColor.a; 
 
 if (a < 0.0 || srcColor.a == 0.0) { 
 FragColor = vec4(0.0, 0.0, 0.0, 0.0); 
 } else { 
 vec3 srcRgb = srcColor.rgb / srcColor.a; 
 FragColor = vec4(srcRgb * a, a); 
 } 
 } 
