#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
    uint mode;
};

struct TerminalVertex {
    packed_float2 position;
    packed_float2 uv;
    packed_float4 color;
    uint mode;
};

vertex VertexOut terminal_vertex(const device TerminalVertex *vertices [[buffer(0)]],
                                 uint vertex_id [[vertex_id]]) {
    VertexOut out;
    out.position = float4(vertices[vertex_id].position, 0.0, 1.0);
    out.uv = vertices[vertex_id].uv;
    out.color = vertices[vertex_id].color;
    out.mode = vertices[vertex_id].mode;
    return out;
}

fragment float4 terminal_fragment(VertexOut in [[stage_in]],
                                  texture2d<float> glyph_atlas [[texture(0)]]) {
    if (in.mode == 1) {
        return in.color;
    }

    constexpr sampler atlas_sampler(address::clamp_to_edge, filter::linear);
    float coverage = glyph_atlas.sample(atlas_sampler, in.uv).r;
    return float4(in.color.rgb, in.color.a * coverage);
}
