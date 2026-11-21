
uniform sampler2D uSrcTexture;
uniform sampler2D uDstTexture;

in vec2 vUV;
out vec4 FragColor;

vec3 One = vec3(1.0, 1.0, 1.0);
struct FragData { vec3 Sc; float Sa; float So; vec3 Dc; float Da; };
FragData d;

void getFragData() {
    // get source data
    vec4 colorSrc = texture(uSrcTexture, vUV);
    vec4 colorDst = texture(uDstTexture, vUV);
    // fill fragment data
    d.Sc = colorSrc.rgb;
    d.Sa = colorSrc.a;
    d.So = 1.0;
    d.Dc = colorDst.rgb;
    d.Da = colorDst.a;
    if (d.Sa > 0.0) { d.Sc = d.Sc / d.Sa; }
}

vec4 postProcess(vec4 R) { return mix(vec4(d.Dc, d.Da), R, d.Sa * d.So); }
