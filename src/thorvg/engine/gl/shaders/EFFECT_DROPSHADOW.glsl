
uniform sampler2D uSrcTexture;
uniform sampler2D uBlrTexture;
layout(std140) uniform DropShadow {
    float sigma;
    float scale;
    float extend;
    float dummy0;
    vec4 color;
    vec2 offset;
} uDropShadow;

in vec2 vUV;
out vec4 FragColor;

void main()
{
    vec2 texelSize = 1.0 / vec2(textureSize(uSrcTexture, 0));
    vec2 offset = uDropShadow.offset * texelSize;
    vec4 orig = texture(uSrcTexture, vUV);
    vec4 blur = texture(uBlrTexture, vUV + offset);
    vec4 shad = uDropShadow.color * blur.a;
    FragColor = orig + shad * (1.0 - orig.a);
} 
