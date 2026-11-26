shader_type canvas_item;
render_mode unshaded;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear;
uniform vec2 target_size = vec2(1.0);
uniform vec2 transform_x = vec2(1.0, 0.0);
uniform vec2 transform_y = vec2(0.0, 1.0);
uniform vec2 transform_origin = vec2(0.0);
uniform vec4 background_color : source_color = vec4(1.0);

void fragment() {
    // Invert the shared center-pivot Transform2D in pixel space. This keeps
    // rotation aspect-correct and matches the card stack's canvas transform.
    vec2 local = SCREEN_UV * target_size - transform_origin;
    float determinant = transform_x.x * transform_y.y - transform_y.x * transform_x.y;
    vec4 output_color = background_color;

    if (abs(determinant) >= 0.000001 && target_size.x > 0.0 && target_size.y > 0.0) {
        vec2 source_pixel = vec2(
            (transform_y.y * local.x - transform_y.x * local.y) / determinant,
            (-transform_x.y * local.x + transform_x.x * local.y) / determinant
        );
        vec2 source_uv = source_pixel / target_size;
        if (source_uv.x >= 0.0 && source_uv.x <= 1.0 && source_uv.y >= 0.0 && source_uv.y <= 1.0) {
            output_color = vec4(texture(screen_texture, source_uv).rgb, 1.0);
        }
    }

    COLOR = output_color;
}
