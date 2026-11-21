uniform sampler2D uSrcTexture; 
 uniform sampler2D uMaskTexture; 
 in vec2 vUV; 
 out vec4 FragColor; 
 
 void main() 
 { 
 vec4 srcColor = texture(uSrcTexture, vUV); 
 vec4 maskColor = texture(uMaskTexture, vUV); 
 vec4 color = srcColor + maskColor * (1.0 - srcColor.a); 
 FragColor = min(color, vec4(1.0, 1.0, 1.0, 1.0)) ; 
 } 
