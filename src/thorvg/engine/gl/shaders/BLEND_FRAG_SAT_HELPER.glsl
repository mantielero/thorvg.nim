
float sat(vec3 color) {
    return max(color.r, max(color.g, color.b)) - min(color.r, min(color.g, color.b));
}

vec3 setSat(vec3 color, float s) {
    float n = min(color.r, min(color.g, color.b));
    float x = max(color.r, max(color.g, color.b));
    return x > n ? (color - vec3(n)) * (s / (x - n)) : vec3(0.0);
}
