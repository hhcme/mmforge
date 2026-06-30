#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float3 worldNormal;
};

struct Uniforms {
    float4x4 mvp;
    float4x4 model;
    float4 baseColor;
    float4 highlightColor;  // rgb = tint, a = blend factor (0 = no highlight)
};

vertex VertexOut vertex_main(VertexIn in [[stage_in]],
                             constant Uniforms& u [[buffer(2)]]) {
    VertexOut out;
    out.position = u.mvp * float4(in.position, 1.0);
    out.worldNormal = (u.model * float4(in.normal, 0.0)).xyz;
    return out;
}

fragment float4 fragment_main(VertexOut in [[stage_in]],
                               constant Uniforms& u [[buffer(2)]]) {
    float3 lightDir = normalize(float3(1.0, 2.0, 3.0));
    float3 normal = normalize(in.worldNormal);
    float NdotL = max(dot(normal, lightDir), 0.15); // ambient floor
    float3 color = u.baseColor.rgb * NdotL;
    // Blend highlight tint over diffuse result.
    color = mix(color, u.highlightColor.rgb, u.highlightColor.a);
    return float4(color, 1.0);
}
