
void main()
{
    getFragData();
    vec3 Rc = d.Sc;
    if (d.Da > 0.0) {
        Rc = d.Sc * min(One, d.Dc / d.Da);
        Rc = mix(d.Sc, Rc, d.Da);
    }
    FragColor = postProcess(vec4(Rc, 1.0));
}
