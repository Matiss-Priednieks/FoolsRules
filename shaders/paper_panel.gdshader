shader_type canvas_item;
// Aged-paper look for a panel's box (the card tooltips): the same cel grime
// blotches and foxing spots as card_fx's paper, so a tooltip reads like a
// scrap of the card rather than a UI box. Only affects the panel itself - its
// Label children draw with their own (text_wear) material.

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
	local_pos = VERTEX;
}

void fragment() {
	vec2 p = local_pos;
	float grime = step(0.62, vnoise(p * 0.02) * 0.7 + vnoise(p * 0.09) * 0.3);
	float fox = step(0.9, vnoise(p * 0.11)) * step(0.5, vnoise(p * 0.025));
	COLOR.rgb *= 1.0 - 0.08 * grime;
	COLOR.rgb = mix(COLOR.rgb, vec3(0.62, 0.46, 0.28), fox * 0.45);
}
