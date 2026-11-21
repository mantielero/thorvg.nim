
uniform sampler2D uSrcTexture;
layout(std140) uniform Params {
    vec4 params[3];
} uParams;

in vec2 vUV;
out vec4 FragColor;

void main()
{
    vec4 orig = texture(uSrcTexture, vUV);
    float luma = dot(orig.rgb, vec3(0.2126, 0.7152, 0.0722));
    FragColor = vec4(mix(orig.rgb, mix(uParams.params[0].rgb, uParams.params[1].rgb, luma), uParams.params[2].r) * orig.a, orig.a);
} 
