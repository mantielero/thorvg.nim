
void main()
{
    getFragData();
    vec3 Rc = max(d.Sc, d.Dc);
    FragColor = postProcess(vec4(Rc, 1.0));
}
