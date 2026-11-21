in vec4 vColor; 
 out vec4 FragColor; 
 
 void main() 
 { 
 vec4 uColor = vColor; 
 FragColor = vec4(uColor.rgb * uColor.a, uColor.a); 
 } 
