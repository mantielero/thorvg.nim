uniform sampler2D uSrcTexture; 
 uniform sampler2D uMaskTexture; 
 in vec2 vUV; 
 out vec4 FragColor; 
 
 void main() 
 { 
 vec4 srcColor = texture(uSrcTexture, vUV); 
 vec4 maskColor = texture(uMaskTexture, vUV); 
 float da = srcColor.a - maskColor.a; 
 if (da == 0.0) { 
 FragColor = vec4(0.0, 0.0, 0.0, 0.0); 
 } else if (da > 0.0) { 
 FragColor = srcColor * da; 
 } else { 
 FragColor = maskColor * (-da); 
 } 
 } 
