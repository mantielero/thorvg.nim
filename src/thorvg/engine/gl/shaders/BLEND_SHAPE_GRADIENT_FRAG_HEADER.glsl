
layout(std140) uniform BlendRegion {
    vec4 region;
} uBlendRegion;

uniform sampler2D uDstTexture;

out vec4 FragColor;

vec3 One = vec3(1.0, 1.0, 1.0);
struct FragData { vec3 Sc; vec3 Dc; float Da; };
FragData d;
vec4 src, dst;

void getFragData() {
    src = gradientColor(vPos);
    vec2 uv = (gl_FragCoord.xy - uBlendRegion.region.xy) / uBlendRegion.region.zw;
    dst = texture(uDstTexture, uv);

    d.Sc = src.rgb;
    d.Dc = dst.rgb;
    if (src.a > 0.0) d.Sc /= src.a;
    if (dst.a > 0.0) d.Dc /= dst.a;
    d.Da = 1.0;
}

vec4 postProcess(vec4 R) {
    return vec4(src.rgb * (1.0 - dst.a) + R.rgb * src.a * dst.a + dst.rgb * (1.0 - src.a),
                src.a + dst.a * (1.0 - src.a));
}
