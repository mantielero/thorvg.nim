layout(std140) uniform ColorInfo { 
 ivec4 params; 
 } uColorInfo; 
 uniform sampler2D uTexture; 
 in vec2 vUV; 
 out vec4 FragColor; 
 
 void main() 
 { 
 FragColor = texture(uTexture, vUV) * float(uColorInfo.params.x) / 255.0; 
 } 
