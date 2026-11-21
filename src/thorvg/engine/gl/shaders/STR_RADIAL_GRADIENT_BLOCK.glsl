layout(std140) uniform GradientInfo {
    vec4 nStops;
    vec4 centerPos;
    vec2 radius;
    vec4 stopPoints[4];
    vec4 stopColors[16];
    mat3 invTransform;
} uGradientInfo;
