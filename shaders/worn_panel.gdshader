shader_type canvas_item;
// Worn painted-metal look for the PlatePanel boxes (pause menu, pre-game
// panel): cel grime blotches, a few rust spots and fine diagonal scratches on
// the dark paint, and the light rim chipped down to bare metal in patches.
// Only the panel's own box - its children draw with their own materials.
// Put on every PlatePanel by the TextWear autoload.

varying vec2 local_pos;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x),
		mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}

void vertex() {
	local_pos = VERTEX; // panel-local, so the wear sticks to the panel
}

void fragment() {
	vec2 p = local_pos;
	bool rim = dot(COLOR.rgb, vec3(0.333)) > 0.3; // the khaki border vs the dark paint
	if (rim) {
		float chip = step(0.6, vnoise(p * 0.09) * 0.7 + vnoise(p * 0.3) * 0.3);
		COLOR.rgb = mix(COLOR.rgb, vec3(0.16, 0.14, 0.11), chip * 0.85); // paint chipped off
	} else {
		float blot = step(0.6, vnoise(p * 0.015) * 0.6 + vnoise(p * 0.06) * 0.4);
		COLOR.rgb *= 1.0 - 0.2 * blot;
		// long thin scratches at an angle, in sparse clusters
		vec2 r = vec2(p.x * 0.92 + p.y * 0.38, -p.x * 0.38 + p.y * 0.92);
		float scratch = step(0.92, vnoise(vec2(r.x * 0.01, r.y * 0.9))) * step(0.45, vnoise(p * 0.008));
		COLOR.rgb += vec3(0.08, 0.072, 0.056) * scratch;
		// a few rust spots
		float rust = step(0.86, vnoise(p * 0.03)) * step(0.4, vnoise(p * 0.011));
		COLOR.rgb = mix(COLOR.rgb, vec3(0.2, 0.09, 0.04), rust * 0.6);
	}
}
