uniform sampler2D uSrcTexture; 
 uniform sampler2D uMaskTexture; 
 in vec2 vUV; 
 out vec4 FragColor; 
 
 void main() 
 { 
 vec4 srcColor = texture(uSrcTexture, vUV); 
 vec4 maskColor = texture(uMaskTexture, vUV); 
 if (srcColor.a > 0.0) srcColor.rgb /= srcColor.a; 
 float alpha = max(srcColor.a, maskColor.a); 
 FragColor = vec4(srcColor.rgb * alpha, alpha); 
 } 
