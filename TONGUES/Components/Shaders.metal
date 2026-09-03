#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

// Noise helpers used by crackGptWiper for the band-edge frill.

static float spHash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

static float spNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = spHash(i);
    float b = spHash(i + float2(1.0, 0.0));
    float c = spHash(i + float2(0.0, 1.0));
    float d = spHash(i + float2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// Animated liquid-glass wiper. A thin refracting band sweeps horizontally
// back and forth across the layer, with chromatic dispersion, multi-band
// halo, and a directional brightness bias so the right-bound pass reads
// brighter than the return.

[[ stitchable ]] half4 crackGptWiper(float2 position,
                                      SwiftUI::Layer layer,
                                      float2 size, float time) {
    float2 uv = position / size;

    // Slow wipe — full back-and-forth cycle every ~4s. Wide overshoot
    // so the wiper travels off-screen at both extremes before reversing.
    float wipePos = sin(time * M_PI_F * 0.5) * 0.85 + 0.5;   // -0.35 -> 1.35

    // Multi-frequency wobble — fast temporal frequencies for shimmer.
    float wobble = sin(uv.y * 24.0  + time * 54.0)  * 0.0055
                 + sin(uv.y * 54.0  + time * 78.0)  * 0.0028
                 + sin(uv.y * 118.0 - time * 45.0)  * 0.0014
                 + sin(uv.y * 240.0 + time * 108.0) * 0.0007;
    float noiseFrill = (spNoise(float2(uv.y * 16.0, time * 33.0)) - 0.5) * 0.0030;
    float lineX = wipePos + wobble + noiseFrill;

    float dx = uv.x - lineX;

    // Dynamic band width — slightly thinner at dim end / on the return.
    float wipePhaseEarly = time * M_PI_F * 0.5;
    float velocityEarly  = cos(wipePhaseEarly);
    float blendToLeftEarly = smoothstep(-0.20, 0.20, -velocityEarly);
    float returnSubtlety = mix(1.0, 0.70, blendToLeftEarly);
    float wipePosOnScreen = clamp(wipePos, 0.0, 1.0);
    float dimFactor = smoothstep(0.0, 0.35, wipePosOnScreen);
    float bandWidth = 0.0009 * mix(0.65, 1.0, dimFactor) * returnSubtlety;

    // Band envelope: drives the thin visible line, halos, crest.
    float env = exp(-dx * dx / (bandWidth * bandWidth));
    float normSlope = -dx / bandWidth * env;
    float crest = exp(-dx * dx / (bandWidth * bandWidth * 0.18));

    // Wider glass-body envelope where refraction happens — decoupled
    // from the thin line so the lens has room to displace text.
    float glassWidth = 0.028;
    float glassEnv   = exp(-dx * dx / (glassWidth * glassWidth));
    float glassSlope = -dx / glassWidth * glassEnv;

    float refractAmp = 350.0;
    float dispersion = 110.0;

    float2 offR = float2(glassSlope * refractAmp + dispersion * glassEnv, 0.0);
    float2 offG = float2(glassSlope * refractAmp,                          0.0);
    float2 offB = float2(glassSlope * refractAmp - dispersion * glassEnv, 0.0);

    half4 base = layer.sample(position);
    half4 sR = layer.sample(position + offR);
    half4 sG = layer.sample(position + offG);
    half4 sB = layer.sample(position + offB);

    half4 refracted = half4(sR.r, sG.g, sB.b,
                              max(sR.a, max(sG.a, sB.a)));

    const half bandOpacity = 0.55h;

    half mixAmount = half(smoothstep(0.0, 0.55, glassEnv)) * 0.85h;
    half4 result = mix(base, refracted, mixAmount);

    // Subtle cool spectrum across the band.
    float bandPos = saturate(dx / bandWidth * 0.5 + 0.5);
    float3 white   = float3(1.00, 1.00, 1.05);
    float3 lightBl = float3(0.62, 0.84, 1.15);
    float3 softWm  = float3(1.05, 0.95, 0.85);

    float coolness = smoothstep(0.45, 0.0, bandPos);
    float warmth   = smoothstep(0.55, 1.0, bandPos);
    float3 spectrum = white;
    spectrum = mix(spectrum, lightBl, coolness * 0.85);
    spectrum = mix(spectrum, softWm,  warmth   * 0.30);

    result.rgb += half(env * 0.28) * half3(spectrum) * bandOpacity;

    half3 crestColor = half3(0.88, 0.96, 1.12);
    result.rgb += half(crest * 0.45) * crestColor * bandOpacity;

    float trough = clamp(-normSlope * 2.0, 0.0, 1.0);
    half troughDark = mix(1.0h, half(mix(1.0, 0.74, trough * 0.50)), bandOpacity);
    result.rgb *= troughDark;

    // Direction-aware intensity: bright peak right-bound, dim on return.
    float wipePhase = time * M_PI_F * 0.5;
    float velocity = cos(wipePhase);
    float blendToLeft = smoothstep(-0.20, 0.20, -velocity);
    float brightRight = sqrt(wipePosOnScreen);
    float brightLeft  = wipePosOnScreen * wipePosOnScreen * 0.125;
    float brightShape = mix(brightRight, brightLeft, blendToLeft);
    half  lightI = half((0.40 + brightShape * 2.35) * returnSubtlety);

    half3 blueLight = half3(0.78, 0.83, 0.98);
    half3 warmHint  = half3(1.22, 0.88, 0.55);

    float bloomW = 0.22;
    float bloom  = exp(-dx * dx / (bloomW * bloomW));
    result.rgb += half(bloom * 0.16) * blueLight * lightI;

    float outerHaloW = 0.12;
    float outerHalo  = exp(-dx * dx / (outerHaloW * outerHaloW));
    result.rgb += half(outerHalo * 0.14) * blueLight * lightI;

    float midHaloW = 0.05;
    float midHalo  = exp(-dx * dx / (midHaloW * midHaloW));
    result.rgb += half(midHalo * 0.18) * blueLight * lightI;

    half linePresence = half(0.70 + brightShape * 0.45);
    float coreW = 0.013;
    float core  = exp(-dx * dx / (coreW * coreW));
    result.rgb += half(core * 0.34) * blueLight * linePresence;

    float warmCoreW = 0.005;
    float warmCore  = exp(-dx * dx / (warmCoreW * warmCoreW));
    result.rgb += half(warmCore * 0.08) * warmHint * linePresence;

    return result;
}

// MARK: - AI "sand" avatar
//
// A low-viscosity liquid rendered on a red disc: thin white tendrils that flow,
// stretch, merge and split organically. The motion comes from domain-warped
// fractal noise (the standard technique for fluid/marbled looks) advected by a
// steady flow, so nothing repeats or snaps. The `amplitude` uniform (0…1, the
// AI's live speech loudness) deepens the warp and brightness when the AI talks;
// when quiet the liquid settles into a slow idle drift.

// Fractional Brownian motion built from the value noise at the top of the file.
static float aiFbm(float2 p) {
    float v = 0.0;
    float a = 0.5;
    // 3 octaves is plenty for a small avatar and keeps the per-pixel cost low.
    for (int i = 0; i < 3; i++) {
        v += a * spNoise(p);
        p = p * 2.0 + 11.3;   // scale + offset per octave to decorrelate
        a *= 0.5;
    }
    return v;
}

[[ stitchable ]] half4 aiSandAvatar(float2 position,
                                    half4 color,
                                    float2 size,
                                    float time,
                                    float amplitude) {
    float amp = clamp(amplitude, 0.0, 1.0);

    // Centered, y-normalized coordinates: the inscribed circle edge is r = 0.5.
    float2 uv = (position - 0.5 * size) / size.y;
    float r = length(uv);

    half3 rimBlue  = half3(0.349h, 0.486h, 0.698h);  // #597CB2 base at the edge
    half3 coreBlue = half3(0.53h, 0.69h, 0.89h);     // brighter blue center
    half3 white    = half3(1.0h, 1.0h, 1.0h);        // liquid

    // Background is a radial gradient: a bright blue core easing out to the
    // base blue at the rim (no white — the disc stays blue edge to edge).
    float centerGlow = exp(-r * r * 4.0);
    half3 col = mix(rimBlue, coreBlue, half(centerGlow));

    // --- Flowing liquid via domain-warped fBm --------------------------------
    // A single domain warp advected by a steady flow gives a low-viscosity
    // fluid that stretches and folds without ever repeating — and stays cheap
    // (3 fBm calls). `amp` only deepens the warp (never multiplies the large
    // `time`, which would jump the phase and flicker), so louder speech makes
    // the liquid churn more energetically.
    float2 p    = uv * 3.2;
    float2 flow = float2(time * 0.11, time * 0.08);   // steady advection
    float  warp = 1.6 + amp * 1.4;

    float2 q = float2(aiFbm(p + flow),
                      aiFbm(p + flow + float2(5.2, 1.3)));
    float fld = aiFbm(p + warp * q);

    // Thin bright tendrils along the flow's mid-contour, plus a broader sheen so
    // the liquid has body rather than reading as loose wires.
    float veins = pow(max(0.0, 1.0 - abs(fld - 0.5) * 2.5), 2.0);
    float sheen = smoothstep(0.44, 0.78, fld);
    float liquid = clamp(veins * 1.05 + sheen * 0.34, 0.0, 1.0);

    // Concentrate toward the middle, fading into the red rim. Loosens a little
    // as the voice gets louder so the liquid spreads outward while speaking.
    float cluster = exp(-r * r * (4.5 - amp * 1.5));
    liquid *= cluster;

    col = mix(col, white, half(liquid) * (0.92h + 0.08h * half(amp)));

    // Gentle whole-core brighten on loud speech.
    col += white * half(amp * 0.10 * cluster);

    return half4(col, 1.0h);
}
