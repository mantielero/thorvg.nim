
uniform sampler2D uSrcTexture;
layout(std140) uniform Params {
    vec2 offset;
    float samples;
} uParams;

layout(std140) uniform Viewport {
    vec4 vp;
} uViewport;

out vec4 FragColor;

void main()
{
    // The pooled texture can be larger than the compositing region.
    // Clamp sampling coordinates to the region's outermost texel centers.
    vec2 invTextureSize = 1.0 / vec2(textureSize(uSrcTexture, 0));
    vec2 maxCoord = uViewport.vp.zw - vec2(0.5);
    int samples = int(uParams.samples);
    float invSamples = 1.0 / float(samples);
    vec4 color = vec4(0.0);
    for (int i = 0; i < samples; ++i) {
        float t = (float(i) + 0.5) * invSamples - 0.5;
        vec2 p = clamp(gl_FragCoord.xy + uParams.offset * t, vec2(0.5), maxCoord);
        color += textureLod(uSrcTexture, p * invTextureSize, 0.0);
    }
    FragColor = color * invSamples;
}
