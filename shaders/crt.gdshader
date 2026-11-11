shader_type canvas_item;
// Whole-screen CRT: barrel curvature, scanlines, aperture-grille RGB mask,
// chromatic aberration, vignette and a gentle flicker. Meant for a full-rect
// ColorRect on a CanvasLayer above everything else.

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;

uniform float curvature     : hint_range(0.0, 0.40) = 0.08; // barrel warp
uniform float bezel         : hint_range(0.0, 0.04) = 0.004; // casing margin around the glass
uniform float tube_radius   : hint_range(0.0, 0.3) = 0.06;  // rounded picture-tube corners
uniform float glass_soft    : hint_range(0.0, 0.02) = 0.004; // softness of the glass edge
uniform vec3 casing_color   : source_color = vec3(0.05, 0.042, 0.034); // dark bakelite
uniform float scanline_amt  : hint_range(0.0, 1.0)  = 0.15;
uniform float scanline_freq : hint_range(200.0, 2000.0) = 1080.0;
uniform float mask_amt      : hint_range(0.0, 1.0)  = 0.10; // RGB subpixel mask
uniform float aberration    : hint_range(0.0, 3.0)  = 0.6;  // colour fringe, in texels
uniform float vignette_amt  : hint_range(0.0, 1.5)  = 0.30;
uniform float flicker_amt   : hint_range(0.0, 0.15) = 0.02;
uniform float brightness    : hint_range(0.5, 2.0)  = 1.10;

vec2 warp(vec2 uv) {
	vec2 c = uv * 2.0 - 1.0;
	c *= vec2(1.0 + c.y * c.y * curvature, 1.0 + c.x * c.x * curvature);
	return c * 0.5 + 0.5;
}

void fragment() {
	vec2 uv = warp(SCREEN_UV);

	// The glass: a rounded rectangle (an old picture tube) in aspect-correct
	// space. d < 0 inside the glass, > 0 out on the casing.
	vec2 aspect = vec2(1.7778, 1.0);
	vec2 tp = (uv - 0.5) * aspect;
	vec2 tq = abs(tp) - (0.5 * aspect - bezel - tube_radius);
	float d = length(max(tq, 0.0)) + min(max(tq.x, tq.y), 0.0) - tube_radius;
	float glass = 1.0 - smoothstep(-glass_soft, glass_soft, d);

	vec3 screen_col = vec3(0.0);
	if (glass > 0.0) {
		vec2 texel = 1.0 / vec2(textureSize(screen_tex, 0));
		vec2 ab = vec2(aberration, 0.0) * texel;
		vec3 col = vec3(
			texture(screen_tex, uv + ab).r,
			texture(screen_tex, uv).g,
			texture(screen_tex, uv - ab).b
		);

		// scanlines
		float scan = 0.5 + 0.5 * sin(uv.y * scanline_freq * 3.14159265);
		col *= 1.0 - scanline_amt + scanline_amt * scan;

		// aperture-grille mask over 3-pixel cells
		vec3 mask = vec3(0.6);
		float cell = mod(FRAGCOORD.x, 3.0);
		if (cell < 1.0) {
			mask = vec3(1.0, 0.6, 0.6);
		} else if (cell < 2.0) {
			mask = vec3(0.6, 1.0, 0.6);
		} else {
			mask = vec3(0.6, 0.6, 1.0);
		}
		col *= mix(vec3(1.0), mask, mask_amt);

		// vignette
		vec2 v = uv * (1.0 - uv.yx);
		col *= clamp(pow(v.x * v.y * 15.0, vignette_amt), 0.0, 1.0);

		// gentle flicker
		col *= 1.0 - flicker_amt * (0.5 + 0.5 * sin(TIME * 96.0));

		screen_col = col * brightness;
		// the tube falls off toward its curved edge
		screen_col *= mix(1.0, 0.6, smoothstep(-0.03, 0.0, d));
	}

	// The casing: grainy dark bakelite, lit a touch from above, a soft lip of
	// light where it meets the glass, and the picture's own glow spilling onto it.
	vec2 sp = SCREEN_UV * vec2(1920.0, 1080.0);
	float grain = fract(sin(dot(floor(sp * 0.5), vec2(12.9898, 78.233))) * 43758.5453);
	vec3 casing = casing_color * (1.15 - 0.3 * SCREEN_UV.y) * (0.92 + 0.16 * grain);
	casing += vec3(0.12, 0.105, 0.085) * exp(-max(d, 0.0) * 260.0) * 0.35;  // lip highlight
	vec3 spill = texture(screen_tex, clamp(uv, vec2(0.02), vec2(0.98)), 4.0).rgb;
	casing += spill * exp(-max(d, 0.0) * 45.0) * 0.06;                     // screen glow spill

	COLOR = vec4(mix(casing, screen_col, glass), 1.0);
}
