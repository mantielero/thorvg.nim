uniform sampler2D uSrcTexture; 
 uniform sampler2D uMaskTexture; 
 in vec2 vUV; 
 out vec4 FragColor; 
 
 void main() { 
 vec4 srcColor = texture(uSrcTexture, vUV); 
 vec4 maskColor = texture(uMaskTexture, vUV); 
 
 if (maskColor.a > 0.000001) { 
 maskColor = vec4(maskColor.rgb / maskColor.a, maskColor.a); 
 } 
 
 FragColor = srcColor * dot(maskColor.rgb, vec3(0.2125, 0.7154, 0.0721)) * maskColor.a; 
 } 
