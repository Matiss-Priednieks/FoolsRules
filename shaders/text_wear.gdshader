shader_type canvas_item;
// Worn ink for UI text: faded patches and dark dirt flecks across the glyphs,
// in the same value-noise style as card_fx's grime. Font-agnostic, and the
// letters stay solid (no transparent holes) - only the ink colour wears. Put on every Label/Button by the TextWear autoload.
// Boxes drawn by the same control (plates, buttons) just get faint grime.

uniform float wear : hint_range(0.0, 1.0) = 0.5;   // how worn the ink is
uniform float scale : hint_range(0.1, 4.0) = 1.0;   // noise size (bigger = finer chips)

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
	local_pos = VERTEX; // control-local: the wear sticks to the text as it moves
}

void fragment() {
	vec2 p = local_pos * scale;
	float n = vnoise(p * 0.12) * 0.6 + vnoise(p * 0.45) * 0.4;
	if (textureSize(TEXTURE, 0).x > 1) { // a glyph from the font atlas
		float faded = step(0.55, n) * wear;                          // hard-edged faded patches
		float fleck = step(1.0 - wear * 0.3, vnoise(p * 0.8));       // small dirt flecks
		vec3 ink = COLOR.rgb;
		vec3 worn = mix(ink, vec3(dot(ink, vec3(0.333))), 0.35) * 0.78 + vec3(0.03, 0.02, 0.0);
		ink = mix(ink, worn, faded);
		COLOR.rgb = mix(ink, ink * 0.55, fleck);
	} else { // the control's own box
		COLOR.rgb *= 1.0 - 0.1 * step(0.62, n);
	}
}
