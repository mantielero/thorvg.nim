uniform sampler2D uSrcTexture; 
 in vec2 vUV; 
 out vec4 FragColor; 
 
 void main() 
 { 
 FragColor = texture(uSrcTexture, vUV); 
 }