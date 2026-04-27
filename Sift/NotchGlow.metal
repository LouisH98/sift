#include <metal_stdlib>
using namespace metal;

[[ stitchable ]] half4 notchGlow(
    float2 position,
    half4 color,
    float2 size,
    float strength,
    float time,
    float red,
    float green,
    float blue
) {
    if (strength <= 0.001 || size.x <= 1.0 || size.y <= 1.0) {
        return half4(0.0h);
    }

    float2 center = float2(size.x * 0.5, 8.0);
    float2 delta = position - center;
    float2 normalized = float2(delta.x / max(size.x, 1.0), delta.y / max(size.y, 1.0));

    float distanceFromNotch = length(float2(normalized.x * 1.72, normalized.y * 1.85));
    float verticalWindow = smoothstep(0.02, 0.11, normalized.y) * smoothstep(0.96, 0.34, normalized.y);
    float core = exp(-distanceFromNotch * 6.7) * verticalWindow * 0.58;

    float angle = atan2(delta.y, delta.x);
    float rayPhase = angle * 18.0 + time * 1.55;
    float secondaryPhase = angle * 9.0 - time * 0.82;
    float rays = pow(max(0.0, sin(rayPhase) * 0.5 + 0.5), 5.0);
    rays += pow(max(0.0, sin(secondaryPhase) * 0.5 + 0.5), 9.0) * 0.54;
    rays *= smoothstep(0.82, 0.0, distanceFromNotch) * verticalWindow;

    float shimmer = sin((position.x * 0.042) + (position.y * 0.028) - (time * 2.7)) * 0.5 + 0.5;
    float bloom = smoothstep(0.74, 0.0, distanceFromNotch) * verticalWindow * 0.24;
    float rayEnergy = (rays * (0.24 + shimmer * 0.08)) + core + (bloom * 1.18);
    float alpha = clamp(rayEnergy * strength * 0.58, 0.0, 0.46);

    float3 baseColor = clamp(float3(red, green, blue), 0.0, 1.0);
    float3 nearColor = mix(baseColor, float3(1.0), 0.28);
    float3 farColor = mix(baseColor, float3(0.04, 0.10, 0.24), 0.18);
    float3 edgeColor = mix(baseColor, float3(1.0), 0.52);
    float colorMix = clamp(distanceFromNotch * 1.5, 0.0, 1.0);
    float3 glowColor = mix(nearColor, farColor, colorMix);
    glowColor = mix(glowColor, edgeColor, rays * 0.12);
    glowColor *= alpha;

    return half4(half3(glowColor), half(alpha));
}
