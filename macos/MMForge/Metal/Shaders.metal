#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float3 worldNormal;
    float3 worldPos;
};

struct Uniforms {
    float4x4 mvp;
    float4x4 model;
    float4 baseColor;
    float4 highlightColor;  // rgb = tint, a = blend factor
    float4 clipPlane;       // xyz=normal, w=distance; w=-999999 when disabled
    uint renderMode;        // 0=solid, 1=wireframe, 2=solid+wire, 3=transparent
};

vertex VertexOut vertex_main(VertexIn in [[stage_in]],
                             constant Uniforms& u [[buffer(2)]]) {
    VertexOut out;
    float4 worldPos = u.model * float4(in.position, 1.0);
    out.position = u.mvp * float4(in.position, 1.0);
    out.worldNormal = (u.model * float4(in.normal, 0.0)).xyz;
    out.worldPos = worldPos.xyz;
    return out;
}

fragment float4 fragment_main(VertexOut in [[stage_in]],
                               constant Uniforms& u [[buffer(2)]]) {
    // Clipping: discard fragments on the negative side of the plane.
    if (u.clipPlane.w > -999990.0) {
        float dist = dot(u.clipPlane.xyz, in.worldPos) + u.clipPlane.w;
        if (dist < 0.0) discard_fragment();
    }

    float3 lightDir = normalize(float3(1.0, 2.0, 3.0));
    float3 normal = normalize(in.worldNormal);
    float NdotL = max(dot(normal, lightDir), 0.15);
    float3 color = u.baseColor.rgb * NdotL;
    color = mix(color, u.highlightColor.rgb, u.highlightColor.a);

    // Transparent mode: use baseColor alpha.
    float alpha = (u.renderMode == 3) ? u.baseColor.a : 1.0;
    return float4(color, alpha);
}
