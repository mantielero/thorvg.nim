layout(std140) uniform GradientInfo {
    vec4 nStops;
    vec2 gradStartPos;
    vec2 gradEndPos;
    vec4 stopPoints[4];
    vec4 stopColors[16];
    mat3 invTransform;
} uGradientInfo;
