
const vec3 LUM_W = vec3(0.3, 0.59, 0.11);

vec3 setLum(vec3 color, float l) {
    color += l - dot(color, LUM_W);
    float ll = l;
    float n = min(color.r, min(color.g, color.b));
    float x = max(color.r, max(color.g, color.b));

    if (n < 0.0) color = ll + (color - ll) * (ll / (ll - n));
    if (x > 1.0) color = ll + (color - ll) * ((1.0 - ll) / (x - ll));
    return color;
}
