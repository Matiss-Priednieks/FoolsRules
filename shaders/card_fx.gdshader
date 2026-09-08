shader_type canvas_item;
render_mode blend_mix;

// Per-card effects, driven from game.gd (card.gd holds one ShaderMaterial per
// card and just sets these params):
//   rot_x / rot_y : fake-3D tilt in radians. + rot_x tips the TOP edge toward
//                   the viewer, + rot_y turns the RIGHT edge toward the viewer.
//                   The card is treated as a flat quad and the sample point is
//                   rotated + perspective-divided, so the far edge really
//                   foreshortens (a trapezoid, not a skewed parallelogram).
//   invalid       : 0 or 1, draws the red "can't play this" diagonal strike.
uniform float rot_x = 0.0;
uniform float rot_y = 0.0;
uniform float cam_dist : hint_range(1.5, 10.0) = 4.0; // smaller = stronger perspective
uniform float invalid = 0.0;

// carry the CanvasItem's modulate (game.gd dims unplayable cards via modulate.a)
// past the fragment stage, which has no MODULATE built-in
varying vec4 v_modulate;

void vertex() {
	v_modulate = COLOR;
}

void fragment() {
	// The near edge grows under perspective; without headroom it spills past the
	// sprite quad and gets clipped. Draw the card inset by an amount that scales
	// with the tilt, so a resting (rot 0) card is untouched but a tilted one has
	// margin for the near edge to grow into.
	float tilt_mag = max(abs(rot_x), abs(rot_y));
	float fit = max(1.0 - tilt_mag * 0.55, 0.4);
	vec2 c = (UV - 0.5) / fit;
	vec3 p = vec3(c, 0.0);

	// rotate the sampling plane by the inverse of the apparent card rotation
	float sx = sin(-rot_x);
	float cx = cos(-rot_x);
	float sy = sin(-rot_y);
	float cy = cos(-rot_y);
	p = vec3(p.x * cy + p.z * sy, p.y, -p.x * sy + p.z * cy); // yaw  (around Y)
	p = vec3(p.x, p.y * cx - p.z * sx, p.y * sx + p.z * cx);  // pitch (around X)

	float w = cam_dist / (cam_dist - p.z); // perspective divide
	vec2 uv = p.xy * w + 0.5;

	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
		COLOR = vec4(0.0);
	} else {
		vec4 tex = texture(TEXTURE, uv);
		float d = abs(uv.x - uv.y);
		float strike = (1.0 - smoothstep(0.03, 0.05, d)) * clamp(invalid, 0.0, 1.0);
		tex.rgb = mix(tex.rgb, vec3(0.85, 0.05, 0.05), strike);
		COLOR = tex * v_modulate; // keep game.gd's dimming (modulate.a)
	}
}
