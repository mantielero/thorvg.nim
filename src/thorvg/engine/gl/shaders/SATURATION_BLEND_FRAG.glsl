
void main() {
    getFragData();
    vec3 Rc = d.Sc;
    if (d.Da > 0.0) {
        vec3 Dc = min(One, d.Dc / d.Da);
        float s = max(d.Sc.r, max(d.Sc.g, d.Sc.b)) - min(d.Sc.r, min(d.Sc.g, d.Sc.b));
        float n = min(Dc.r, min(Dc.g, Dc.b));
        float x = max(Dc.r, max(Dc.g, Dc.b));
        Rc = vec3(0.0);
        if (x > n) Rc = (Dc - vec3(n)) * (s / (x - n));
        Rc = setLum(Rc, dot(Dc, LUM_W));
        Rc = mix(d.Sc, Rc, d.Da);
    }
    FragColor = postProcess(vec4(Rc, 1.0));
}
