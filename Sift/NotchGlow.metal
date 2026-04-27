#include <metal_stdlib>
using namespace metal;

struct NotchGlowUniforms {
    float4 sizeStrengthTime;
    float4 notchGain;
    float4 glowColor;
    float4 shape;
};

struct NotchGlowVertexOut {
    float4 position [[position]];
    float2 unitPosition;
};

vertex NotchGlowVertexOut notchGlowVertex(uint vertexID [[vertex_id]]) {
    constexpr float2 positions[4] = {
        float2(-1.0, 1.0),
        float2(1.0, 1.0),
        float2(-1.0, -1.0),
        float2(1.0, -1.0)
    };
    constexpr float2 unitPositions[4] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(0.0, 1.0),
        float2(1.0, 1.0)
    };

    NotchGlowVertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.unitPosition = unitPositions[vertexID];
    return out;
}

static float segmentDistance(float2 point, float2 start, float2 end) {
    float2 segment = end - start;
    float t = clamp(dot(point - start, segment) / max(dot(segment, segment), 0.0001), 0.0, 1.0);
    return length(point - (start + (segment * t)));
}

static float roundedBoxDistance(float2 point, float2 center, float2 halfSize, float radius) {
    float2 q = abs(point - center) - (halfSize - float2(radius));
    return length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
}

static float4 topEdgeLineGlowSample(
    float2 position,
    float2 size,
    float strength,
    float time,
    float3 inputColor,
    float2 notchSize,
    float edrGain,
    float topOffsetInput
) {
    if (strength <= 0.001 || size.x <= 1.0 || size.y <= 1.0) {
        return float4(0.0);
    }

    float lineWidth = clamp(notchSize.x, 96.0, size.x * 0.92);
    float tabHeight = clamp(notchSize.y * 2.4, 10.0, 18.0);
    float topY = max(0.0, topOffsetInput);
    float centerX = size.x * 0.5;
    float halfLine = lineWidth * 0.5;
    float lineLeft = centerX - halfLine;
    float lineRight = centerX + halfLine;
    float normalizedX = (position.x - centerX) / max(halfLine, 1.0);

    float2 tabCenter = float2(centerX, topY);
    float2 tabHalfSize = float2(halfLine, tabHeight);
    float tabRadius = tabHeight * 0.58;
    float tabDistance = roundedBoxDistance(position, tabCenter, tabHalfSize, tabRadius);
    float lineDistance = segmentDistance(position, float2(lineLeft + tabRadius, topY), float2(lineRight - tabRadius, topY));
    float capSoftness = smoothstep(5.0, -1.2, tabDistance);
    float horizontalTaper = smoothstep(lineLeft - 42.0, lineLeft + 28.0, position.x)
        * (1.0 - smoothstep(lineRight - 28.0, lineRight + 42.0, position.x));
    float downwardMask = smoothstep(topY - 2.0, topY + 1.0, position.y)
        * (1.0 - smoothstep(topY + 28.0, topY + 128.0, position.y));
    float breath = 0.96 + (sin(time * 1.55) * 0.04);

    float innerFill = smoothstep(1.6, -1.8, tabDistance) * 0.72;
    float rimCore = exp(-pow(abs(tabDistance) / 1.35, 2.0)) * capSoftness * 0.92;
    float bloom = exp(-pow(max(tabDistance, 0.0) / 10.5, 2.0)) * 0.5;
    float halo = exp(-pow(max(tabDistance, 0.0) / 31.0, 2.0)) * 0.22;
    float wash = exp(-pow(abs(position.y - (topY + 18.0)) / 31.0, 2.0))
        * exp(-pow(abs(normalizedX) / 0.92, 4.0))
        * 0.32;
    float lipHighlight = exp(-pow(lineDistance / 2.2, 2.0))
        * exp(-pow((position.y - topY) / 4.8, 2.0))
        * 0.52;
    float energy = (innerFill + rimCore + bloom + halo + wash + lipHighlight) * horizontalTaper * downwardMask * breath;
    float alpha = clamp(energy * strength, 0.0, 0.82);

    float3 baseColor = clamp(inputColor, 0.0, 1.0);
    float3 leftBlue = mix(float3(0.16, 0.34, 1.0), baseColor, 0.18);
    float3 centerCyan = mix(float3(0.70, 0.96, 1.0), baseColor, 0.12);
    float3 rightViolet = mix(float3(0.58, 0.26, 1.0), baseColor, 0.12);
    float3 sideColor = mix(leftBlue, rightViolet, smoothstep(-0.92, 0.92, normalizedX));
    float3 glowColor = mix(sideColor, centerCyan, clamp(rimCore * 0.54 + innerFill * 0.28 + wash * 0.34, 0.0, 0.88));
    glowColor = mix(glowColor, float3(1.0), clamp(rimCore * 0.42 + lipHighlight * 0.48, 0.0, 0.72));
    glowColor *= alpha * edrGain;

    return float4(glowColor, alpha);
}

static float4 notchGlowSample(
    float2 position,
    float2 size,
    float strength,
    float time,
    float3 inputColor,
    float2 notchSize,
    float edrGain,
    float topRadiusInput,
    float bottomRadiusInput,
    float topOffsetInput
) {
    if (strength <= 0.001 || size.x <= 1.0 || size.y <= 1.0) {
        return float4(0.0);
    }

    float safeNotchWidth = clamp(notchSize.x, 96.0, size.x * 0.92);
    float safeNotchHeight = clamp(notchSize.y, 18.0, size.y * 0.82);
    float topY = max(0.0, topOffsetInput);
    float centerX = size.x * 0.5;
    float lipY = topY + safeNotchHeight + 2.0;
    float halfNotch = safeNotchWidth * 0.5;
    float notchLeft = centerX - halfNotch;
    float notchRight = centerX + halfNotch;
    float topRadius = clamp(topRadiusInput, 2.0, safeNotchHeight * 0.32);
    float bottomRadius = clamp(bottomRadiusInput, 4.0, safeNotchHeight * 0.42);
    float sideLeft = notchLeft + topRadius;
    float sideRight = notchRight - topRadius;
    float bottomY = topY + safeNotchHeight;
    float shoulderY = safeNotchHeight - bottomRadius;
    shoulderY += topY;
    float openingProgress = smoothstep(74.0, 150.0, safeNotchHeight);

    float2 lipDelta = position - float2(centerX, lipY);
    float yBelowLip = max(position.y - lipY, 0.0);
    float normalizedX = lipDelta.x / max(halfNotch, 1.0);

    float verticalFalloff = exp(-yBelowLip / mix(68.0, 34.0, openingProgress));
    float horizontalFalloff = exp(-pow(abs(lipDelta.x) / (halfNotch * 1.42), 2.0));
    float bodyWash = horizontalFalloff * verticalFalloff * smoothstep(lipY - 4.0, lipY + 10.0, position.y) * 0.15;

    float hotLip = exp(-pow(abs(yBelowLip - 1.6) / 3.4, 2.0))
        * exp(-pow(abs(normalizedX) / 0.76, 6.0));

    float lipBloom = exp(-pow(abs(yBelowLip - 7.0) / 15.0, 2.0))
        * exp(-pow(abs(normalizedX) / 0.95, 4.0));

    float bottomRimDistance = min(
        segmentDistance(position, float2(sideLeft, topY + topRadius), float2(sideLeft, shoulderY)),
        segmentDistance(position, float2(sideRight, topY + topRadius), float2(sideRight, shoulderY))
    );
    bottomRimDistance = min(bottomRimDistance, segmentDistance(
        position,
        float2(sideLeft + bottomRadius, bottomY),
        float2(sideRight - bottomRadius, bottomY)
    ));

    float leftCornerDistance = abs(length(position - float2(sideLeft + bottomRadius, shoulderY)) - bottomRadius);
    float rightCornerDistance = abs(length(position - float2(sideRight - bottomRadius, shoulderY)) - bottomRadius);
    float leftCornerMask = step(position.x, sideLeft + bottomRadius) * step(shoulderY, position.y);
    float rightCornerMask = step(sideRight - bottomRadius, position.x) * step(shoulderY, position.y);
    bottomRimDistance = min(bottomRimDistance, mix(9999.0, leftCornerDistance, leftCornerMask));
    bottomRimDistance = min(bottomRimDistance, mix(9999.0, rightCornerDistance, rightCornerMask));

    float topSideDistance = min(
        segmentDistance(position, float2(sideLeft, topY), float2(sideLeft, shoulderY)),
        segmentDistance(position, float2(sideRight, topY), float2(sideRight, shoulderY))
    );
    float topEdgeDistance = abs(position.y - topY);
    float topEdgeLeftMask = smoothstep(notchLeft - 58.0, notchLeft + 10.0, position.x)
        * smoothstep(notchLeft + 76.0, notchLeft + 18.0, position.x);
    float topEdgeRightMask = smoothstep(notchRight - 10.0, notchRight + 18.0, position.x)
        * smoothstep(notchRight + 76.0, notchRight + 18.0, position.x);
    float topEdgeMask = max(topEdgeLeftMask, topEdgeRightMask);

    float leftTopCornerDistance = abs(length(position - float2(sideLeft + topRadius, topY + topRadius)) - topRadius);
    float rightTopCornerDistance = abs(length(position - float2(sideRight - topRadius, topY + topRadius)) - topRadius);
    float leftTopCornerMask = step(position.x, sideLeft + topRadius) * step(position.y, topY + topRadius);
    float rightTopCornerMask = step(sideRight - topRadius, position.x) * step(position.y, topY + topRadius);
    float topCornerDistance = min(
        mix(9999.0, leftTopCornerDistance, leftTopCornerMask),
        mix(9999.0, rightTopCornerDistance, rightTopCornerMask)
    );

    float rimDistance = min(bottomRimDistance, topSideDistance);
    rimDistance = min(rimDistance, topCornerDistance);

    float rimVerticalMask = smoothstep(topY - 2.0, topY + topRadius + 1.0, position.y)
        * smoothstep(size.y * 0.55, bottomY + 18.0, position.y);
    float sideClimbMask = smoothstep(size.y * 0.32, shoulderY + 18.0, position.y);
    float topEdgeCore = exp(-pow(topEdgeDistance / 1.15, 2.0)) * topEdgeMask * 0.54;
    float topEdgeBloom = exp(-pow(topEdgeDistance / 8.0, 2.0)) * topEdgeMask * 0.24;
    float verticalTaper = mix(
        1.0,
        mix(0.34, 1.0, smoothstep(topY + topRadius * 1.6, bottomY - bottomRadius * 0.35, position.y)),
        openingProgress
    );
    float climbVisibility = max(rimVerticalMask, sideClimbMask * 0.82) * verticalTaper;
    float rimCore = exp(-pow(rimDistance / 1.08, 2.0)) * climbVisibility;
    float rimBloom = exp(-pow(rimDistance / 5.6, 2.0)) * climbVisibility;
    float rimHalo = exp(-pow(rimDistance / 13.0, 2.0)) * max(rimVerticalMask, sideClimbMask * 0.68) * verticalTaper * 0.28;

    float shoulderDistance = min(
        length(float2(position.x - sideLeft, position.y - shoulderY) / float2(30.0, 23.0)),
        length(float2(position.x - sideRight, position.y - shoulderY) / float2(30.0, 23.0))
    );
    float shoulderBloom = exp(-pow(shoulderDistance, 2.0)) * mix(0.72, 0.46, openingProgress);
    float sideBloom = (
        exp(-pow(length((position - float2(sideLeft, topY + safeNotchHeight * 0.46)) / float2(38.0, 58.0)), 2.0))
        + exp(-pow(length((position - float2(sideRight, topY + safeNotchHeight * 0.46)) / float2(38.0, 58.0)), 2.0))
    ) * 0.34;
    float innerCornerBloom = (
        exp(-pow(length((position - float2(sideLeft + bottomRadius, bottomY - 1.0)) / float2(38.0, 24.0)), 2.0))
        + exp(-pow(length((position - float2(sideRight - bottomRadius, bottomY - 1.0)) / float2(38.0, 24.0)), 2.0))
    ) * 0.16;
    float outerCornerBloom = (
        exp(-pow(length((position - float2(sideLeft + topRadius, topY + topRadius)) / float2(52.0, 34.0)), 2.0))
        + exp(-pow(length((position - float2(sideRight - topRadius, topY + topRadius)) / float2(52.0, 34.0)), 2.0))
    ) * 0.58;
    float upperMask = smoothstep(lipY - 8.0, lipY + 2.0, position.y);
    float lowerMask = smoothstep(size.y * 0.72, lipY + 22.0, position.y);
    float lipSuppression = mix(1.0, 0.18, openingProgress);
    float sideFade = smoothstep(size.x * 0.02, size.x * 0.24, position.x)
        * smoothstep(size.x * 0.98, size.x * 0.76, position.x);

    float breath = 0.96 + (sin(time * 1.55) * 0.04);
    float lowerLipEnergy = (
        (bodyWash * 0.72)
        + (lipBloom * 0.26)
        + (hotLip * 0.34)
        + shoulderBloom
        + (innerCornerBloom * 0.12)
        + (outerCornerBloom * 0.56)
        + (sideBloom * 0.12)
    ) * upperMask * lowerMask * lipSuppression;
    float contourEnergy = (
        (rimHalo * 0.92)
        + (rimBloom * 1.08)
        + (rimCore * 1.54)
        + (innerCornerBloom * 0.26)
        + (outerCornerBloom * 1.36)
        + (sideBloom * mix(1.0, 0.72, openingProgress))
    );
    float topEdgeEnergy = (topEdgeBloom * 0.62) + (topEdgeCore * 1.12);
    float energy = (lowerLipEnergy + contourEnergy + topEdgeEnergy) * sideFade * breath;
    float alpha = clamp(energy * strength, 0.0, 0.86);

    float3 baseColor = clamp(inputColor, 0.0, 1.0);
    float3 leftBlue = mix(float3(0.16, 0.34, 1.0), baseColor, 0.18);
    float3 centerCyan = mix(float3(0.70, 0.96, 1.0), baseColor, 0.12);
    float3 rightViolet = mix(float3(0.58, 0.26, 1.0), baseColor, 0.12);
    float horizontalMix = smoothstep(-0.92, 0.92, normalizedX);
    float3 sideColor = mix(leftBlue, rightViolet, horizontalMix);
    float3 glowColor = mix(sideColor, centerCyan, clamp(hotLip * 0.64 + lipBloom * 0.3 + rimCore * 0.86 + topEdgeCore * 0.28, 0.0, 0.92));

    float whiteHot = clamp((rimCore * 0.92) + (topEdgeCore * 0.42) + (hotLip * 0.36), 0.0, 0.82);
    glowColor = mix(glowColor, float3(1.0), whiteHot);
    glowColor *= alpha * edrGain;

    return float4(glowColor, alpha);
}

fragment half4 notchGlowFragment(
    NotchGlowVertexOut in [[stage_in]],
    constant NotchGlowUniforms &uniforms [[buffer(0)]]
) {
    float2 size = uniforms.sizeStrengthTime.xy;
    float2 position = in.unitPosition * size;
    float4 color;
    if (uniforms.shape.w > 0.5) {
        color = topEdgeLineGlowSample(
            position,
            size,
            uniforms.sizeStrengthTime.z,
            uniforms.sizeStrengthTime.w,
            uniforms.glowColor.rgb,
            uniforms.notchGain.xy,
            uniforms.notchGain.z,
            uniforms.shape.z
        );
    } else {
        color = notchGlowSample(
            position,
            size,
            uniforms.sizeStrengthTime.z,
            uniforms.sizeStrengthTime.w,
            uniforms.glowColor.rgb,
            uniforms.notchGain.xy,
            uniforms.notchGain.z,
            uniforms.shape.x,
            uniforms.shape.y,
            uniforms.shape.z
        );
    }

    return half4(color);
}

[[ stitchable ]] half4 notchGlow(
    float2 position,
    half4 color,
    float2 size,
    float strength,
    float time,
    float red,
    float green,
    float blue,
    float notchWidth,
    float notchHeight
) {
    float4 output = notchGlowSample(
        position,
        size,
        strength,
        time,
        float3(red, green, blue),
        float2(notchWidth, notchHeight),
        1.0,
        6.0,
        14.0,
        0.0
    );

    return half4(output);
}
