uniform float uDepth; 
 uniform mat3 uViewMatrix; 
 layout(location = 0) in vec2 aLocation; 
 out vec2 vPos; 
 void main() 
 { 
 vec3 glPos = uViewMatrix * vec3(aLocation, 1.0); 
 gl_Position = vec4(glPos.xy, uDepth, 1.0); 
 vec3 pos = uGradientInfo.invTransform * vec3(aLocation, 1.0); 
 vPos = pos.xy; 
 } 
