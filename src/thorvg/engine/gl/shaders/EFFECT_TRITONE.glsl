
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
    bool isBright = luma >= 0.5f;
    float t = isBright ? (luma - 0.5f) * 2.0f : luma * 2.0f;
    vec3 from = isBright ? uParams.params[1].rgb : uParams.params[0].rgb;
    vec3 to = isBright ? uParams.params[2].rgb : uParams.params[1].rgb;
    vec4 tmp = vec4(mix(from, to, t), 1.0f);

    if (uParams.params[2].a > 0.0f) tmp = mix(tmp, orig, uParams.params[2].a);
    FragColor = tmp * orig.a;
} 
