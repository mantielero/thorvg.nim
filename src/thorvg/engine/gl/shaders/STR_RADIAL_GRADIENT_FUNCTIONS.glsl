mat3 radial_matrix(vec2 p0, vec2 p1) 
 { 
 mat3 a = mat3(0.0, -1.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0); 
 mat3 b = mat3(p1.y - p0.y, p0.x - p1.x, 0.0, p1.x - p0.x, p1.y - p0.y, 0.0, p0.x, p0.y, 1.0); 
 return a * inverse(b); 
 } 
 
 vec2 compute_radial_t(vec2 c0, float r0, vec2 c1, float r1, vec2 pos) 
 { 
 const float scalar_nearly_zero = 2.44140625e-4; 
 float d_center = distance(c0, c1); 
 float d_radius = r1 - r0; 
 bool radial = d_center < scalar_nearly_zero; 
 bool strip = abs(d_radius) < scalar_nearly_zero; 
 
 if (radial) { 
 if (strip) return vec2(0.0, -1.0); 
 
 float scale = 1.0 / d_radius; 
 float scale_sign = sign(d_radius); 
 float bias = r0 / d_radius; 
 vec2 pt = (pos - c0) * scale; 
 float t = length(pt) * scale_sign - bias; 
 return vec2(t, 1.0); 
 } else if (strip) { 
 mat3 transform = radial_matrix(c0, c1); 
 float r = r0 / d_center; 
 float r_2 = r * r; 
 vec2 pt = (transform * vec3(pos.xy, 1.0)).xy; 
 float t = r_2 - pt.y * pt.y; 
 
 if (t < 0.0) return vec2(0.0, -1.0); 
 
 t = pt.x + sqrt(t); 
 return vec2(t, 1.0); 
 } else { 
 float f = r0 / (r0 - r1); 
 bool is_swapped = abs(f - 1.0) < scalar_nearly_zero; 
 vec2 c0p = is_swapped ? c1 : c0; 
 vec2 c1p = is_swapped ? c0 : c1; 
 float fp = is_swapped ? 0.0 : f; 
 vec2 cf = c0p * (1.0 - fp) + c1p * fp; 
 mat3 transform = radial_matrix(cf, c1p); 
 
 float scale_x = abs(1.0 - fp); 
 float scale_y = scale_x; 
 float r1n = abs(r1 - r0) / d_center; 
 bool is_focal_on_circle = abs(r1n - 1.0) < scalar_nearly_zero; 
 if (is_focal_on_circle) { 
 scale_x *= 0.5; 
 scale_y *= 0.5; 
 } else { 
 float denom = r1n * r1n - 1.0; 
 scale_x *= r1n / denom; 
 scale_y /= sqrt(abs(denom)); 
 } 
 transform = mat3(scale_x, 0.0, 0.0, 0.0, scale_y, 0.0, 0.0, 0.0, 1.0) * transform; 
 
 vec2 pt = (transform * vec3(pos.xy, 1.0)).xy; 
 
 float inv_r1 = 1.0 / r1n; 
 float d_radius_sign = sign(1.0 - fp); 
 
 float x_t = -1.0; 
 if (is_focal_on_circle) x_t = dot(pt, pt) / pt.x; 
 else if (r1n > 1.0) x_t = length(pt) - pt.x * inv_r1; 
 else { 
 float discriminant = pt.x * pt.x - pt.y * pt.y; 
 float root = sqrt(max(discriminant, 0.0)); 
 float s = (is_swapped == (d_radius_sign > 0.0)) ? 1.0 : -1.0; 
 x_t = s * root - pt.x * inv_r1; 
 if (discriminant < 0.0 || x_t < 0.0) return vec2(is_swapped ? 0.0 : 1.0, 1.0); 
 } 
 float t = fp + d_radius_sign * x_t; 
 if (is_swapped) t = 1.0 - t; 
 return vec2(t, 1.0); 
 } 
 } 
 
 vec4 gradientColor(vec2 pos) 
 { 
 vec2 res = compute_radial_t(uGradientInfo.centerPos.xy, 
 uGradientInfo.radius.x, 
 uGradientInfo.centerPos.zw, 
 uGradientInfo.radius.y, 
 pos); 
 if (res.y < 0.0) return vec4(0.0, 0.0, 0.0, 0.0); 
 
 float t = gradientWrap(res.x); 
 vec4 color = gradient(t, res.x, length(pos - uGradientInfo.centerPos.xy)); 
 return vec4(color.rgb * color.a, color.a); 
 } 
