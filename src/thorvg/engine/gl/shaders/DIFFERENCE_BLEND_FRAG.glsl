
void main() {
    getFragData();
    vec3 Rc = abs(d.Dc - d.Sc);
    FragColor = postProcess(vec4(Rc, 1.0));
}
