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

struct NotchProcessingUniforms {
    float4 sizeTimeShape;
    float4 state;
    float4 shape;
    float4 glowColor;
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

static float quadraticValue(float start, float control, float end, float progress) {
    float inverse = 1.0 - progress;
    return (inverse * inverse * start) + (2.0 * inverse * progress * control) + (progress * progress * end);
}

static float2 quadraticPoint(float2 start, float2 control, float2 end, float progress) {
    return float2(
        quadraticValue(start.x, control.x, end.x, progress),
        quadraticValue(start.y, control.y, end.y, progress)
    );
}

static float2 processingContourSample(int index, float2 size, float topRadiusInput, float bottomRadiusInput) {
    float maximumRadius = max(0.0, min(size.x * 0.5, size.y * 0.5));
    float topRadius = min(topRadiusInput, maximumRadius);
    float bottomRadius = min(bottomRadiusInput, maximumRadius);
    float2 start = float2(0.0, 0.0);
    float2 leftTopEnd = float2(topRadius, topRadius);
    float2 leftBottomStart = float2(topRadius, size.y - bottomRadius);
    float2 leftBottomEnd = float2(topRadius + bottomRadius, size.y);
    float2 rightBottomStart = float2(size.x - topRadius - bottomRadius, size.y);
    float2 rightBottomEnd = float2(size.x - topRadius, size.y - bottomRadius);
    float2 rightTopStart = float2(size.x - topRadius, topRadius);

    if (index <= 0) {
        return start;
    }
    if (index <= 8) {
        return quadraticPoint(start, float2(topRadius, 0.0), leftTopEnd, float(index) / 8.0);
    }
    if (index == 9) {
        return leftBottomStart;
    }
    if (index <= 17) {
        return quadraticPoint(leftBottomStart, float2(topRadius, size.y), leftBottomEnd, float(index - 9) / 8.0);
    }
    if (index == 18) {
        return rightBottomStart;
    }
    if (index <= 26) {
        return quadraticPoint(rightBottomStart, float2(size.x - topRadius, size.y), rightBottomEnd, float(index - 18) / 8.0);
    }
    if (index == 27) {
        return rightTopStart;
    }

    return quadraticPoint(rightTopStart, float2(size.x - topRadius, 0.0), float2(size.x, 0.0), float(index - 27) / 8.0);
}

static float2 processingContourMetrics(float2 position, float2 size, float topRadius, float bottomRadius) {
    float walkedLength = 0.0;
    float closestDistance = 9999.0;
    float closestWalkedLength = 0.0;
    float2 previous = processingContourSample(0, size, topRadius, bottomRadius);

    for (int index = 1; index < 36; index++) {
        float2 current = processingContourSample(index, size, topRadius, bottomRadius);
        float2 segment = current - previous;
        float segmentLength = max(length(segment), 0.0001);
        float t = clamp(dot(position - previous, segment) / max(dot(segment, segment), 0.0001), 0.0, 1.0);
        float distance = length(position - (previous + (segment * t)));

        if (distance < closestDistance) {
            closestDistance = distance;
            closestWalkedLength = walkedLength + (segmentLength * t);
        }

        walkedLength += segmentLength;
        previous = current;
    }

    float closestProgress = closestWalkedLength / max(walkedLength, 0.0001);

    return float2(closestDistance, closestProgress);
}

static float rangeMask(float progress, float start, float end, float feather) {
    return smoothstep(start - feather, start + feather, progress)
        * (1.0 - smoothstep(end - feather, end + feather, progress));
}

static float rangeFade(float progress, float start, float end) {
    float width = max(end - start, 0.0001);
    float center = (start + end) * 0.5;
    return clamp(1.0 - (abs(progress - center) / (width * 0.5)), 0.0, 1.0);
}

static float4 processingBounceRange(float phase, float segmentLength) {
    float position = clamp(phase, 0.0, 1.0);
    float compressedLength = segmentLength * 0.56;
    float travelDuration = 0.38;
    float squeezeDuration = 0.06;
    float recoverDuration = 0.06;
    float start = 0.0;
    float end = segmentLength;

    if (position < travelDuration) {
        float progress = position / travelDuration;
        start = progress * (1.0 - segmentLength);
        end = start + segmentLength;
    } else if (position < travelDuration + squeezeDuration) {
        float progress = smoothstep(0.0, 1.0, (position - travelDuration) / squeezeDuration);
        start = mix(1.0 - segmentLength, 1.0 - compressedLength, progress);
        end = 1.0;
    } else if (position < travelDuration + squeezeDuration + recoverDuration) {
        float progress = smoothstep(0.0, 1.0, (position - travelDuration - squeezeDuration) / recoverDuration);
        start = mix(1.0 - compressedLength, 1.0 - segmentLength, progress);
        end = 1.0;
    } else if (position >= 0.5 && position < 0.5 + travelDuration) {
        float progress = (position - 0.5) / travelDuration;
        end = mix(1.0, segmentLength, progress);
        start = end - segmentLength;
    } else if (position >= 0.5 + travelDuration && position < 0.5 + travelDuration + squeezeDuration) {
        float progress = smoothstep(0.0, 1.0, (position - 0.5 - travelDuration) / squeezeDuration);
        end = mix(segmentLength, compressedLength, progress);
        start = 0.0;
    } else {
        float progress = smoothstep(0.0, 1.0, (position - 0.5 - travelDuration - squeezeDuration) / recoverDuration);
        end = mix(compressedLength, segmentLength, progress);
        start = 0.0;
    }

    return float4(start, end, 0.0, 0.0);
}

static float processingClosedShapeMask(float2 position, float2 size, float topRadiusInput, float bottomRadiusInput, float blurRadius) {
    float maximumRadius = max(0.0, min(size.x * 0.5, size.y * 0.5));
    float topRadius = min(topRadiusInput, maximumRadius);
    float bottomRadius = min(bottomRadiusInput, maximumRadius);
    float2 center = float2(size.x * 0.5, size.y * 0.5);
    float2 halfSize = size * 0.5;
    float distance = roundedBoxDistance(position, center, halfSize, max(topRadius, bottomRadius) * 0.72);
    return smoothstep(blurRadius, -blurRadius, distance);
}

static float4 notchProcessingSample(
    float2 position,
    float2 size,
    float isDistilling,
    float queuedOpacity,
    float completionProgress,
    float tracerPhase,
    float topRadius,
    float bottomRadius,
    float segmentLength,
    float3 inputColor,
    float edrGain
) {
    float3 baseColor = clamp(inputColor, 0.0, 1.0);
    float3 outputColor = float3(0.0);
    float outputAlpha = 0.0;

    if (queuedOpacity > 0.001) {
        float radius = length(position - float2(size.x * 0.5, size.y));
        float radial = 0.0;
        if (radius < 2.0) {
            radial = 1.0;
        } else if (radius < 67.0) {
            radial = mix(1.0, 0.36, (radius - 2.0) / 65.0);
        } else if (radius < 132.0) {
            radial = mix(0.36, 0.0, (radius - 67.0) / 65.0);
        }

        float shapeMask = processingClosedShapeMask(position, size, topRadius, bottomRadius, 9.0);
        float alpha = radial * 0.18 * queuedOpacity * shapeMask;
        outputColor += baseColor * alpha;
        outputAlpha = max(outputAlpha, alpha);
    }

    float2 contour = processingContourMetrics(position, size, topRadius, bottomRadius);
    float distance = contour.x;
    float progress = contour.y;

    if (isDistilling > 0.001) {
        float4 range = processingBounceRange(tracerPhase, segmentLength);
        float mask = rangeMask(progress, range.x, range.y, 0.006);
        float coreFade = rangeFade(progress, range.x, range.y);
        float opacity = 0.92 * isDistilling;

        float wideGlow = exp(-pow(max(distance - 2.7, 0.0) / 4.6, 2.0)) * mask * opacity * 0.30;
        float midGlow = exp(-pow(max(distance - 0.9, 0.0) / 0.9, 2.0)) * mask * opacity * 0.56;
        float core = smoothstep(0.56, 0.18, distance) * mask * coreFade * opacity;

        outputColor += baseColor * (wideGlow + midGlow);
        outputColor += float3(1.0) * core;
        outputAlpha = max(outputAlpha, clamp(wideGlow + midGlow + core, 0.0, 1.0));
    }

    float completionOpacity = max(0.0, 1.0 - completionProgress);
    if (completionOpacity > 0.001) {
        float lineWidth = 1.0 + (completionProgress * 6.0);
        float blurRadius = 8.0 + (completionProgress * 10.0);
        float glow = exp(-pow(max(distance - (lineWidth * 0.5), 0.0) / blurRadius, 2.0)) * completionOpacity * 0.45;
        float coreWidth = max(0.6, 1.6 - completionProgress);
        float core = smoothstep(coreWidth * 0.5 + 0.44, coreWidth * 0.5 - 0.1, distance) * completionOpacity * 0.56;

        outputColor += baseColor * glow;
        outputColor += float3(1.0) * core;
        outputAlpha = max(outputAlpha, clamp(glow + core, 0.0, 1.0));
    }

    return float4(outputColor * edrGain, clamp(outputAlpha, 0.0, 1.0));
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
);

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
);

static float4 topEdgeProcessingSample(
    float2 position,
    float2 size,
    float time,
    float isDistilling,
    float queuedOpacity,
    float completionProgress,
    float tracerPhase,
    float3 inputColor,
    float edrGain
) {
    float topRadius = min(5.0, size.y * 0.20);
    float bottomRadius = min(15.0, size.y * 0.48);

    return notchProcessingSample(
        position,
        size,
        isDistilling,
        queuedOpacity,
        completionProgress,
        tracerPhase,
        topRadius,
        bottomRadius,
        0.18,
        inputColor,
        edrGain
    );
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

    float lineWidth = clamp(notchSize.x, 132.0, size.x * 0.92);
    float tabHeight = clamp(notchSize.y, 18.0, 34.0);
    float topY = max(0.0, topOffsetInput);
    float centerX = size.x * 0.5;
    float halfLine = lineWidth * 0.5;
    float2 virtualNotchSize = float2(lineWidth, tabHeight);
    float4 notch = notchGlowSample(
        position,
        size,
        strength,
        time,
        inputColor,
        virtualNotchSize,
        edrGain,
        5.0,
        min(15.0, tabHeight * 0.50),
        topY
    );

    float normalizedX = (position.x - centerX) / max(halfLine, 1.0);
    float bottomY = topY + tabHeight;
    float bottomLip = exp(-pow(abs(position.y - bottomY) / 1.8, 2.0))
        * exp(-pow(abs(normalizedX) / 0.76, 6.0));
    float centerLip = exp(-pow(abs(position.y - (bottomY + 1.8)) / 5.2, 2.0))
        * exp(-pow(abs(normalizedX) / 0.58, 6.0));
    float centerBloom = exp(-pow(abs(position.y - (bottomY + 8.0)) / 24.0, 2.0))
        * exp(-pow(abs(normalizedX) / 0.48, 4.0));
    float sideShoulders = (
        exp(-pow(length((position - float2(centerX - halfLine, topY + tabHeight * 0.42)) / float2(20.0, 28.0)), 2.0))
        + exp(-pow(length((position - float2(centerX + halfLine, topY + tabHeight * 0.42)) / float2(20.0, 28.0)), 2.0))
    );
    float extraEnergy = ((bottomLip * 0.32) + (centerLip * 0.30) + (centerBloom * 0.24) + (sideShoulders * 0.12)) * strength;
    float3 baseColor = clamp(inputColor, 0.0, 1.0);
    float centerHeat = clamp((bottomLip * 0.48) + (centerLip * 0.72) + (centerBloom * 0.36), 0.0, 0.82);
    float3 extraColor = mix(baseColor, float3(1.0), centerHeat) * extraEnergy * edrGain;

    return float4(notch.rgb + extraColor, max(notch.a, clamp(extraEnergy, 0.0, 0.46)));
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

fragment half4 notchProcessingFragment(
    NotchGlowVertexOut in [[stage_in]],
    constant NotchProcessingUniforms &uniforms [[buffer(0)]]
) {
    float2 size = uniforms.sizeTimeShape.xy;
    float2 position = in.unitPosition * size;
    float shape = uniforms.sizeTimeShape.w;
    float4 color;

    if (shape > 0.5) {
        color = topEdgeProcessingSample(
            position,
            size,
            uniforms.sizeTimeShape.z,
            uniforms.state.x,
            uniforms.state.y,
            uniforms.state.z,
            uniforms.state.w,
            uniforms.glowColor.rgb,
            uniforms.glowColor.w
        );
    } else {
        color = notchProcessingSample(
            position,
            size,
            uniforms.state.x,
            uniforms.state.y,
            uniforms.state.z,
            uniforms.state.w,
            uniforms.shape.x,
            uniforms.shape.y,
            uniforms.shape.z,
            uniforms.glowColor.rgb,
            uniforms.glowColor.w
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
