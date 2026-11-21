
void main() {
    getFragData();
    vec3 Rc = d.Sc;
    if (d.Da > 0.0) {
        vec3 Dc = min(One, d.Dc / d.Da);
        Rc = setLum(d.Sc, dot(Dc, LUM_W));
        Rc = mix(d.Sc, Rc, d.Da);
    }
    FragColor = postProcess(vec4(Rc, 1.0));
}
