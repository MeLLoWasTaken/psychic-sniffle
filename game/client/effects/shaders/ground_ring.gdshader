// Ground effect circle (a flat quad scaled to the radius): a school-colored fill that sweeps out
// from the centre (progress 0..1) with swirling bands, and an outline ring at the full radius
// whose color says who cast it (red-tinted for enemies, neutral for allies: docs/DESIGN.md).
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform vec4 fill_color : source_color = vec4(1.0);
uniform vec4 outline_color : source_color = vec4(1.0, 0.1, 0.06, 0.95);
instance uniform float outline_frac = 0.05;  // outline width / radius
instance uniform float progress = 1.0;
uniform float fill_alpha = 0.35;
uniform float intensity = 1.3;
instance uniform float alpha = 1.0;

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	if (r > 1.0) {
		discard;
	}
	float aa = fwidth(r) * 1.5;
	float ring = smoothstep(1.0 - outline_frac - aa, 1.0 - outline_frac, r) * (1.0 - smoothstep(1.0 - aa, 1.0, r));
	float front = exp(-pow((r - progress) / 0.07, 2.0)) * step(0.02, progress) * (1.0 - step(0.999, progress));
	float inside = 1.0 - smoothstep(progress - 0.02, progress, r);
	float swirl = 0.5 + 0.5 * sin(atan(p.y, p.x) * 7.0 + r * 14.0 - TIME * 4.0);
	float fill = fill_alpha * inside * (0.5 + 0.5 * swirl) * (0.35 + 0.65 * r);
	float fa = clamp(fill + front * 0.6, 0.0, 1.0);
	vec3 fc = fill_color.rgb * intensity;
	vec3 oc = outline_color.rgb * intensity;
	float oa = ring * outline_color.a;
	ALBEDO = mix(fc, oc, oa / max(oa + fa * (1.0 - oa), 1e-4));
	ALPHA = clamp(oa + fa * (1.0 - oa), 0.0, 1.0) * alpha;
}
