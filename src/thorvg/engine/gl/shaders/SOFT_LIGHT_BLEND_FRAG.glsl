
void main() {
    getFragData();
    vec3 Rc = d.Sc;
    if (d.Da > 0.0) {
        vec3 Dc = min(One, d.Dc / d.Da);
        vec3 Dlow = ((16.0 * Dc - 12.0) * Dc + 4.0) * Dc;
        vec3 Dhigh = sqrt(Dc);
        vec3 D = mix(Dhigh, Dlow, step(Dc, vec3(0.25)));
        vec3 low = Dc - (1.0 - 2.0 * d.Sc) * Dc * (1.0 - Dc);
        vec3 high = Dc + (2.0 * d.Sc - 1.0) * (D - Dc);
        Rc = mix(high, low, step(d.Sc, vec3(0.5)));
        Rc = clamp(Rc, vec3(0.0), One);
        Rc = mix(d.Sc, Rc, d.Da);
    }
    FragColor = postProcess(vec4(Rc, 1.0));
}
