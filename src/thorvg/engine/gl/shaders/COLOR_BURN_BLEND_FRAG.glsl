
void main() {
    getFragData();
    vec3 Rc = d.Sc;
    if (d.Da > 0.0) {
        vec3 Dc = min(One, d.Dc / d.Da);
        Rc.r = d.Sc.r > 0.0 ? 1.0 - min(1.0, (1.0 - Dc.r) / d.Sc.r) : Dc.r < 1.0 ? 0.0 : 1.0;
        Rc.g = d.Sc.g > 0.0 ? 1.0 - min(1.0, (1.0 - Dc.g) / d.Sc.g) : Dc.g < 1.0 ? 0.0 : 1.0;
        Rc.b = d.Sc.b > 0.0 ? 1.0 - min(1.0, (1.0 - Dc.b) / d.Sc.b) : Dc.b < 1.0 ? 0.0 : 1.0;
        Rc = mix(d.Sc, Rc, d.Da);
    }
    FragColor = postProcess(vec4(Rc, 1.0));
}
