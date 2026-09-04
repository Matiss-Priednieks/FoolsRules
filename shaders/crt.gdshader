shader_type canvas_item;
// Whole-screen CRT: barrel curvature, scanlines, aperture-grille RGB mask,
// chromatic aberration, vignette and a gentle flicker. Meant for a full-rect
// ColorRect on a CanvasLayer above everything else.

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;

uniform float curvature     : hint_range(0.0, 0.40) = 0.08; // barrel warp
uniform float bezel         : hint_range(0.0, 0.04) = 0.004; // black edge thickness
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

	if (any(lessThan(uv, vec2(bezel))) || any(greaterThan(uv, vec2(1.0 - bezel)))) {
		COLOR = vec4(0.0, 0.0, 0.0, 1.0); // outside the glass
	} else {
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

		COLOR = vec4(col * brightness, 1.0);
	}
}
