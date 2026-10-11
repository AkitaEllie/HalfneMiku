// A drop shadow behind a control's artwork.
//
// The original puts a `DropShadowFilter(2, 45, 0, 0.5, 8, 8, 1)` on every
// `mLabel` -- the backdrop thumbnails, the eye sets, the vowel shapes and the
// backdrop transforms alike -- so the art sits above the pane rather than flat
// on it. Godot has no drop-shadow filter for a Control, so this reproduces it:
// the texture is drawn at an offset with its alpha spread by a small blur and
// tinted black, then composited under the original.
//
// The offset is scaled by the texture's own height, because the filters are in
// stage pixels and these are drawn at different sizes.
shader_type canvas_item;

uniform vec2 offset_scale = vec2(0.0, 0.0);
uniform float blur = 2.0;
uniform float alpha = 0.0;
uniform vec4 shadow_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);

void fragment() {
	// The art, read straight and untouched.
	vec4 art = texture(TEXTURE, UV);

	// The shadow is a copy of the alpha, offset and blurred along the filter's
	// 45-degree axis. It is drawn only *outside* the artwork -- masking by the
	// source alpha keeps it from smearing across the icon's own transparent
	// margins and onto the button's white interior, which is what put a grey
	// band inside the chrome before.
	if (alpha > 0.0) {
		vec2 px = 1.0 / vec2(textureSize(TEXTURE, 0));
		vec2 step = vec2(0.707, 0.707) * blur;
		vec2 uv = UV - offset_scale * blur * 0.75;

		float a = texture(TEXTURE, uv).a;
		a += texture(TEXTURE, uv + px * step * 1.5).a;
		a += texture(TEXTURE, uv - px * step * 1.5).a;
		a += texture(TEXTURE, uv + px * step * 3.0).a;
		a += texture(TEXTURE, uv - px * step * 3.0).a;
		a /= 5.0;
		a *= a;
		a = clamp(a - art.a, 0.0, 1.0) * shadow_color.a * alpha;
		vec4 shadow = vec4(shadow_color.rgb, a);
		COLOR = art + shadow * (1.0 - art.a);
	} else {
		COLOR = art;
	}
}