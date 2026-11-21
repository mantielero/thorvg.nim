uniform float uDepth; 
 uniform mat3 uViewMatrix; 
 layout(location = 0) in vec2 aLocation; 
 layout(location = 1) in vec4 aColor; 
 out vec4 vColor; 
 
 void main() 
 { 
 vec3 pos = uViewMatrix * vec3(aLocation, 1.0); 
 gl_Position = vec4(pos.xy, uDepth, 1.0); 
 vColor = aColor; 
 } 
