
uniform sampler2D uSrcTexture;
layout(std140) uniform Gaussian {
    float sigma;
    float scale;
    float extend;
    float quality;
} uGaussian;

layout(std140) uniform Viewport {
    vec4 vp;
} uViewport;

in vec2 vUV;
out vec4 FragColor;

float gaussian(float x, float sigma) {
    float exponent = -x * x / (2.0 * sigma * sigma);
    return exp(exponent) / (sqrt(2.0 * 3.141592) * sigma);
}

void main()
{
    vec2 texelSize = 1.0 / vec2(textureSize(uSrcTexture, 0));
    vec4 colorSum = vec4(0.0);
    float sigma = uGaussian.sigma * uGaussian.scale;
    float weightSum = 0.0;
    int radius = int(uGaussian.extend);
    int quality = int(uGaussian.quality);
    vec2 texelStep = vec2(texelSize.x, 0.0);

    // Clamp the kernel range once so edge pixels skip taps outside the valid viewport.
    int first = max(-radius, int(ceil(uViewport.vp.x - gl_FragCoord.x)));
    int last = min(radius, int(ceil(uViewport.vp.z - gl_FragCoord.x)) - 1);
    int remainder = first % quality;
    if (remainder < 0) remainder += quality;
    if (remainder > 0) first += quality - remainder;
    vec2 coord = vUV + texelStep * float(first);
    vec2 sampleStep = texelStep * float(quality);
    for (int x = first; x <= last; x += quality) {
        float weight = gaussian(float(x), sigma);
        colorSum += texture(uSrcTexture, coord) * weight;
        weightSum += weight;
        coord += sampleStep;
    }
    FragColor = weightSum > 0.0 ? colorSum / weightSum : texture(uSrcTexture, vUV);
} 
