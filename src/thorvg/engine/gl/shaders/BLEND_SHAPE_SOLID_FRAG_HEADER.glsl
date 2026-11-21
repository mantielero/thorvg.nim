
layout(std140) uniform BlendRegion {
    vec4 region;
} uBlendRegion;

uniform sampler2D uDstTexture;

in vec4 vColor;
out vec4 FragColor;

vec3 One = vec3(1.0, 1.0, 1.0);
struct FragData { vec3 Sc; float Sa; float So; vec3 Dc; float Da; };
FragData d;

void getFragData() {
    vec2 uv = (gl_FragCoord.xy - uBlendRegion.region.xy) / uBlendRegion.region.zw;
    vec4 colorSrc = vColor;
    vec4 colorDst = texture(uDstTexture, uv);
    d.Sc = colorSrc.rgb * colorSrc.a;
    d.Sa = colorSrc.a;
    d.So = 1.0;
    d.Dc = colorDst.rgb;
    d.Da = colorDst.a;
}

vec4 postProcess(vec4 R) { return R; }
