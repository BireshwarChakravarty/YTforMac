// Metal Shading Language source for Encore's GPU visualisers.
//
// The renderer is a small multi-pass pipeline modelled on the techniques that
// make the best visualisers look premium (MilkDrop/Butterchurn feedback, the
// additive particle glow of Magnetosphere, film-style post-processing):
//
//   1. scene      → HDR scene texture (fragment scene, or background + particles)
//   2. feedback   → accum = scene + warp(previous accum) × decay   (light trails)
//   3. bloom      → bright pass + 5-level dual-filter down/up chain
//   4. composite  → accum + bloom, ACES tonemap, vignette, subtle chromatic
//                   aberration on beats, film grain/dither
//
// Compiled at runtime (no .metallib needed); `Scripts/check-shaders.sh`
// compiles it offline in CI so shader mistakes fail the build.

enum MetalShaders {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 res;
    float time;
    float bass;
    float mid;
    float treble;
    float level;
    float phase;
    float scroll;
    float dpr;
    float beat;
    float pad1;
    float4 p0;
    float4 p1;
    float4 p2;
    float4 shadow;
};

struct PassParams {
    float2 srcTexel;
    float2 outSize;
    float decay;
    float zoom;
    float rot;
    float warp;
    float maxMode;
    float threshold;
    float bloomAmt;
    float exposure;
};

constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
constexpr sampler artSampler(coord::normalized, address::mirrored_repeat, filter::linear, mip_filter::linear);
constexpr sampler spriteSampler(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear);

static float hash1(float n) { return fract(sin(n) * 43758.5453123); }
static float hash2(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
static float2 grad2(float2 i) { float a = hash2(i) * 6.2831853; return float2(cos(a), sin(a)); }
static float gnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float a = dot(grad2(i), f), b = dot(grad2(i + float2(1, 0)), f - float2(1, 0));
    float c = dot(grad2(i + float2(0, 1)), f - float2(0, 1)), d = dot(grad2(i + float2(1, 1)), f - float2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y) * 0.7 + 0.5;
}
static float fbm3(float2 p) {
    float v = 0.0, a = 0.5;
    float2x2 m = float2x2(float2(1.6, 1.2), float2(-1.2, 1.6));
    for (int i = 0; i < 3; i++) { v += a * gnoise(p); p = m * p; a *= 0.5; }
    return v;
}
static float3 pal(constant Uniforms &u, float t) {
    t = fract(t);
    float s = t * 3.0;
    if (s < 1.0) return mix(u.p0.rgb, u.p1.rgb, s);
    if (s < 2.0) return mix(u.p1.rgb, u.p2.rgb, s - 1.0);
    return mix(u.p2.rgb, u.p0.rgb, s - 2.0);
}
static float spec(texture2d<float> t, float x) {
    return t.sample(linearSampler, float2(clamp(x, 0.0, 1.0) * 0.92 + 0.02, 0.5), level(0)).r;
}
static float2 fragCoord(float4 pos, constant Uniforms &u) { return float2(pos.x, u.res.y - pos.y); }
static float2x2 rot(float a) { float c = cos(a), s = sin(a); return float2x2(float2(c, -s), float2(s, c)); }

struct QuadOut { float4 position [[position]]; };

vertex QuadOut quadVertex(uint vid [[vertex_id]]) {
    const float2 P[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    QuadOut o;
    o.position = float4(P[vid], 0, 1);
    return o;
}

struct PointOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float3 color;
};

fragment float4 pointFragment(PointOut in [[stage_in]], float2 pc [[point_coord]]) {
    float m = (1.0 - smoothstep(0.05, 0.5, length(pc - 0.5)));
    return float4(in.color * m, 1.0);
}

// ================================================================ post-processing

fragment float4 feedbackFragment(QuadOut in [[stage_in]],
                                 constant Uniforms &u [[buffer(0)]],
                                 constant PassParams &pp [[buffer(1)]],
                                 texture2d<float> sceneTex [[texture(0)]],
                                 texture2d<float> prevTex [[texture(1)]]) {
    float2 uv = in.position.xy / pp.outSize;
    // Clamp HDR: dense additive particles can otherwise overflow half floats to
    // infinity, which tonemaps to black.
    float3 sc = clamp(sceneTex.sample(linearSampler, uv).rgb, 0.0, 48.0);
    if (any(isnan(sc))) sc = float3(0.0);
    float3 prev = float3(0.0);
    if (pp.decay > 0.0) {
        float aspect = pp.outSize.x / pp.outSize.y;
        float2 c = uv - 0.5;
        c.x *= aspect;
        c = rot(pp.rot) * c / pp.zoom;
        c += pp.warp * 0.012 * float2(sin(c.y * 6.0 + u.time * 0.6) + sin(c.y * 13.0 - u.time * 0.9) * 0.4,
                                      cos(c.x * 5.0 - u.time * 0.5) + cos(c.x * 11.0 + u.time * 0.8) * 0.4);
        c.x /= aspect;
        prev = prevTex.sample(linearSampler, c + 0.5).rgb;
        prev = max(prev * pp.decay - 0.0015, 0.0);
    }
    return float4(min(mix(sc + prev, max(sc, prev), pp.maxMode), 48.0), 1.0);
}

fragment float4 brightFragment(QuadOut in [[stage_in]],
                               constant PassParams &pp [[buffer(1)]],
                               texture2d<float> src [[texture(0)]]) {
    float2 uv = in.position.xy / pp.outSize;
    float3 c = src.sample(linearSampler, uv).rgb;
    float l = max(c.r, max(c.g, c.b));
    float knee = 0.5;
    float soft = clamp(l - pp.threshold + knee, 0.0, 2.0 * knee);
    soft = soft * soft / (4.0 * knee + 1e-4);
    float w = max(soft, l - pp.threshold) / max(l, 1e-4);
    return float4(c * w, 1.0);
}

fragment float4 downFragment(QuadOut in [[stage_in]],
                             constant PassParams &pp [[buffer(1)]],
                             texture2d<float> src [[texture(0)]]) {
    float2 uv = in.position.xy / pp.outSize;
    float2 h = pp.srcTexel;
    float3 s = src.sample(linearSampler, uv).rgb * 4.0;
    s += src.sample(linearSampler, uv - h).rgb + src.sample(linearSampler, uv + h).rgb;
    s += src.sample(linearSampler, uv + float2(h.x, -h.y)).rgb + src.sample(linearSampler, uv - float2(h.x, -h.y)).rgb;
    return float4(s / 8.0, 1.0);
}

fragment float4 upFragment(QuadOut in [[stage_in]],
                           constant PassParams &pp [[buffer(1)]],
                           texture2d<float> src [[texture(0)]],
                           texture2d<float> base [[texture(1)]]) {
    float2 uv = in.position.xy / pp.outSize;
    float2 h = pp.srcTexel;
    float3 s = src.sample(linearSampler, uv + float2(-h.x * 2.0, 0.0)).rgb + src.sample(linearSampler, uv + float2(h.x * 2.0, 0.0)).rgb;
    s += src.sample(linearSampler, uv + float2(0.0, -h.y * 2.0)).rgb + src.sample(linearSampler, uv + float2(0.0, h.y * 2.0)).rgb;
    s += (src.sample(linearSampler, uv + h).rgb + src.sample(linearSampler, uv - h).rgb
          + src.sample(linearSampler, uv + float2(h.x, -h.y)).rgb + src.sample(linearSampler, uv - float2(h.x, -h.y)).rgb) * 2.0;
    return float4(s / 12.0 + base.sample(linearSampler, uv).rgb, 1.0);
}

static float3 aces(float3 x) { return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0); }

fragment float4 compositeFragment(QuadOut in [[stage_in]],
                                  constant Uniforms &u [[buffer(0)]],
                                  constant PassParams &pp [[buffer(1)]],
                                  texture2d<float> src [[texture(0)]],
                                  texture2d<float> bloom [[texture(1)]]) {
    float2 uv = in.position.xy / pp.outSize;
    float2 d = uv - 0.5;
    float ca = (0.0012 + u.beat * 0.0018) * pp.rot;     // chromatic aberration (per scene; 0 for the painted cabin)
    float3 col = float3(src.sample(linearSampler, uv - d * ca).r, src.sample(linearSampler, uv).g, src.sample(linearSampler, uv + d * ca).b);
    col += bloom.sample(linearSampler, uv).rgb * pp.bloomAmt * 0.2;
    col *= pp.exposure;
    col = aces(col);
    col = pow(col, float3(1.0 / 1.12));
    float vig = (1.0 - smoothstep(0.25, 1.15, length(d * float2(1.0, 0.9))));
    col *= mix(0.55, 1.0, vig);
    col += (hash2(in.position.xy + fract(u.time) * 91.0) - 0.5) * (2.5 / 255.0);
    return float4(col, 1.0);
}

// ================================================================ Classic
// A hi-fi spectrum analyser in the spirit of the classic desktop players: LED
// segment bars (green to amber to red) with peak caps that fall back slowly,
// mirrored on a dark glass floor, and a phosphor oscilloscope trace above.

static float waveAt(texture2d<float> w, float x) {
    return w.sample(linearSampler, float2(clamp(x, 0.0, 1.0) * (255.0 / 256.0) + 0.5 / 256.0, 0.5), level(0)).r * 2.0 - 1.0;
}
static float peakAt(texture2d<float> t, float x) {
    return t.sample(linearSampler, float2(clamp(x, 0.0, 1.0) * 0.92 + 0.02, 0.5), level(0)).r;
}
static float3 classicLed(float h) {
    float3 c = mix(float3(0.10, 1.0, 0.30), float3(1.0, 0.86, 0.12), smoothstep(0.45, 0.68, h));
    return mix(c, float3(1.0, 0.18, 0.10), smoothstep(0.76, 0.9, h));
}

fragment float4 classicFragment(QuadOut in [[stage_in]],
                                constant Uniforms &u [[buffer(0)]],
                                texture2d<float> specTex [[texture(0)]],
                                texture2d<float> waveTex [[texture(6)]],
                                texture2d<float> peakTex [[texture(7)]]) {
    float2 fc = fragCoord(in.position, u);
    float2 p = (fc - 0.5 * u.res) / u.res.y;              // height units, y up
    float aspect = u.res.x / u.res.y;
    float px = 1.0 / u.res.y;
    float3 col = mix(float3(0.006, 0.008, 0.012), float3(0.022, 0.026, 0.038), smoothstep(-0.5, 0.5, p.y));
    col += float3(0.02, 0.04, 0.03) * exp(-pow(p.y + 0.06, 2.0) * 30.0);   // glow along the floor
    float W = min(aspect * 0.88, 1.75);
    float fx = (p.x + W * 0.5) / W;
    float floorY = -0.06, topY = 0.3;
    float N = floor(clamp(W * 26.0, 24.0, 48.0));
    if (fx > 0.0 && fx < 1.0) {
        float bi = floor(fx * N), bf = fract(fx * N);
        float centre = (bi + 0.5) / N;
        float v = spec(specTex, centre);
        float pk = max(peakAt(peakTex, centre), v);
        float inBar = smoothstep(0.08, 0.08 + N * px / W * 1.5, bf) * (1.0 - smoothstep(0.92 - N * px / W * 1.5, 0.92, bf));
        float segs = 28.0;
        float h = (p.y - floorY) / (topY - floorY);
        float hr = (floorY - p.y) / (topY - floorY);       // mirrored, below the floor
        float hh = h > 0.0 ? h : hr;
        float si = floor(hh * segs), sf = fract(hh * segs);
        float sh = (si + 0.5) / segs;
        float gap = smoothstep(0.12, 0.2, sf) * (1.0 - smoothstep(0.86, 0.94, sf));
        float lit = step(sh, v);
        float cap = step(abs(sh - (floor(pk * segs) + 0.5) / segs), 0.01) * step(0.03, pk);
        float3 led = classicLed(sh);
        float3 seg = led * (lit * (1.6 + 0.8 * u.beat * step(sh, 0.3)) + 0.018) + float3(1.0, 0.95, 0.85) * cap * 1.8;
        if (hh > 0.0 && hh < 1.0) {
            float m = inBar * gap;
            if (h > 0.0) col = mix(col, seg, m);
            else col = mix(col, seg * 0.22 * exp(-hr * 4.0), m * (0.6 + 0.4 * sin(p.y * 900.0 + u.time * 2.0) * 0.1));
        }
    }
    // the floor line
    col += float3(0.25, 0.35, 0.3) * exp(-abs(p.y - floorY) / (px * 1.5)) * step(abs(p.x), W * 0.5) * 0.25;
    // oscilloscope
    float sy = 0.395, sa = 0.055;
    if (abs(p.y - sy) < sa * 1.6 && abs(p.x) < W * 0.5) {
        float d = 1e3;
        float x = fx;
        float dx = 1.5 / (W * u.res.y);
        for (int k = -3; k <= 3; k++) {
            float x0 = x + float(k) * dx;
            float x1 = x0 + dx;
            float2 a = float2((x0 - 0.5) * W, sy + sa * waveAt(waveTex, x0));
            float2 b = float2((x1 - 0.5) * W, sy + sa * waveAt(waveTex, x1));
            float2 ab = b - a, ap = p - a;
            d = min(d, length(ap - ab * clamp(dot(ap, ab) / dot(ab, ab), 0.0, 1.0)));
        }
        float3 phos = float3(0.35, 1.0, 0.75);
        col += phos * (exp(-d * d / (px * px * 1.2)) * 1.6 + exp(-d / (px * 9.0)) * 0.18);
        // graticule
        float gx = abs(fract((p.x / W + 0.5) * 10.0) - 0.5) * W / 10.0;
        col += float3(0.05, 0.12, 0.09) * (exp(-gx / px) + exp(-abs(p.y - sy) / px)) * 0.35;
    }
    // faint scanlines and a vignette of the panel
    col *= 0.92 + 0.08 * sin(fc.y * 3.14159);
    return float4(col, 1.0);
}

// ================================================================ Warp
// MilkDrop-style: every frame a glowing waveform shape (a ring, a line or a
// Lissajous figure, drifting between them) is drawn into the feedback buffer,
// which zooms, turns and ripples it into tunnels of colour that change with
// the music.

static float warpSeg(float2 p, float2 a, float2 b) {
    float2 ab = b - a, ap = p - a;
    return length(ap - ab * clamp(dot(ap, ab) / dot(ab, ab), 0.0, 1.0));
}

fragment float4 warpFragment(QuadOut in [[stage_in]],
                             constant Uniforms &u [[buffer(0)]],
                             texture2d<float> specTex [[texture(0)]],
                             texture2d<float> waveTex [[texture(6)]]) {
    float2 uv = (fragCoord(in.position, u) - 0.5 * u.res) / u.res.y;
    float px = 1.0 / u.res.y;
    float t = u.time;
    float cyc = t / 14.0;
    float k = fract(cyc);
    float shape = floor(cyc);
    float mixT = smoothstep(0.8, 1.0, k);
    // colours: the artwork's palette, drifting around the colour wheel
    float3 hue = mix(pal(u, t * 0.03 + u.phase * 0.02), 0.5 + 0.5 * cos(6.2831853 * (t * 0.021 + float3(0.0, 0.33, 0.67))), 0.45);
    float3 hue2 = mix(pal(u, t * 0.03 + 0.4), 0.5 + 0.5 * cos(6.2831853 * (t * 0.021 + 0.45 + float3(0.0, 0.33, 0.67))), 0.45);
    float3 col = float3(0.0);
    for (int s = 0; s < 2; s++) {
        float which = fmod(shape + float(s), 3.0);
        float wgt = s == 0 ? 1.0 - mixT : mixT;
        if (wgt < 0.01) continue;
        float d = 1e3;
        if (which < 0.5) {
            // a ring that breathes with the bass, its edge the waveform
            float r = length(uv), a = atan2(uv.y, uv.x);
            float x = a / 6.2831853 + 0.5;
            float R = 0.17 + 0.05 * u.bass + 0.055 * waveAt(waveTex, x) * smoothstep(0.0, 0.06, min(x, 1.0 - x));
            d = abs(r - R);
        } else if (which < 1.5) {
            // a horizontal trace, mirrored
            float x = uv.x * 0.6 + 0.5;
            float y = 0.12 * waveAt(waveTex, x) * smoothstep(0.0, 0.15, min(x, 1.0 - x));
            d = min(abs(uv.y - y), abs(uv.y + y));
        } else {
            // a Lissajous figure: left against a quarter-turn later
            float2 prev = float2(0.0);
            for (int i = 0; i <= 48; i++) {
                float x = float(i) / 48.0;
                float2 q = 0.26 * float2(waveAt(waveTex, x), waveAt(waveTex, fract(x + 0.27)));
                q = rot(t * 0.2) * q;
                if (i > 0) d = min(d, warpSeg(uv, prev, q));
                prev = q;
            }
        }
        float w = px * (1.3 + 1.5 * u.beat);
        col += mix(hue, hue2, 0.5 + 0.5 * sin(t * 0.7 + float(s))) * (exp(-d * d / (w * w)) * 1.4 + exp(-d / (px * 6.0)) * 0.12) * wgt;
    }
    // sparks on the treble
    float2 g = uv * 18.0;
    float2 gi = floor(g);
    float h = hash2(gi + floor(t * 4.0));
    col += hue2 * step(0.985 - u.treble * 0.02, h) * exp(-length(fract(g) - 0.5) * 8.0) * 2.0 * u.treble;
    return float4(col, 1.0);
}

// ================================================================ Halo
// The artwork as a slowly turning record with a glossy label, on a glow of its
// own colours, ringed by a radial spectrum of rounded bars with peak dots that
// fall back slowly, leaving soft trails.

fragment float4 haloFragment(QuadOut in [[stage_in]],
                             constant Uniforms &u [[buffer(0)]],
                             texture2d<float> specTex [[texture(0)]],
                             texture2d<float> artTex [[texture(2)]],
                             texture2d<float> peakTex [[texture(7)]]) {
    float2 uv = (fragCoord(in.position, u) - 0.5 * u.res) / u.res.y - float2(0.0, 0.06);
    float px = 1.0 / u.res.y;
    float r = length(uv), a = atan2(uv.y, uv.x);
    float R = 0.19 * (1.0 + 0.035 * u.beat);
    // a dim glow of the artwork's colours behind everything
    float2 buv = rot(u.time * 0.02) * uv * 0.45 + 0.5;
    float3 col = artTex.sample(artSampler, buv, level(7.0)).rgb * 0.16 * exp(-r * 1.6);
    col += pal(u, 0.15) * exp(-pow(r - R * 1.1, 2.0) * 60.0) * 0.06 * (0.6 + u.bass);
    // the spectrum: rounded bars with peak dots
    float n = 80.0;
    float fa = fract(a / (2.0 * M_PI_F) + 0.25);
    float cell = floor(fa * n);
    float centerA = (cell + 0.5) / n;
    float seg = abs(centerA * 2.0 - 1.0);
    float sv = spec(specTex, seg * 0.85);
    float pk = max(peakAt(peakTex, seg * 0.85), sv);
    float r0 = R * 1.14;
    float len = 0.012 + sv * 0.2;
    float aDist = abs(fa - centerA) * 2.0 * M_PI_F * r;
    float w = 0.0034;
    float dy = r - clamp(r, r0, r0 + len);
    float bar = length(float2(aDist, dy)) - w;
    float3 barCol = mix(mix(u.p0.rgb, u.p2.rgb, seg), u.p1.rgb, smoothstep(0.0, 0.2, r - r0)) * (0.55 + 1.2 * sv);
    col = mix(col, barCol, 1.0 - smoothstep(-px, px, bar));
    float pr = r0 + 0.012 + pk * 0.2 + 0.014;
    float pdot = length(float2(aDist, r - pr)) - w * 0.85;
    col = mix(col, mix(u.p1.rgb, float3(1.0), 0.6) * 1.4, (1.0 - smoothstep(-px, px, pdot)) * step(0.04, pk));
    // the record
    if (r < R * 1.1) {
        float2 ruv = rot(-u.time * (0.08 + 0.25 * u.level)) * uv;
        float3 disc = float3(0.018, 0.018, 0.022);
        float grooves = 0.5 + 0.5 * sin(r * 900.0);
        float sheen = pow(abs(sin(atan2(ruv.y, ruv.x) * 2.0 + 0.6)), 6.0);
        disc += float3(0.05, 0.05, 0.06) * grooves * sheen * smoothstep(R * 0.98, R * 1.0, r);
        if (r < R) {
            float2 auv = float2(ruv.x, -ruv.y) / (2.0 * R) + 0.5;
            disc = artTex.sample(artSampler, auv, level(0)).rgb * (0.92 + 0.18 * u.beat);
            // gloss across the label and a fine rim
            float gloss = pow(max(0.0, dot(normalize(uv + 1e-4), normalize(float2(-0.6, 0.8)))), 6.0) * smoothstep(0.0, R, r);
            disc += float3(1.0) * gloss * 0.12;
            disc *= 1.0 - 0.35 * smoothstep(R * 0.9, R, r);
        }
        float edge = 1.0 - smoothstep(R * 1.1 - px, R * 1.1, r);
        col = mix(col, disc, edge);
        col += pal(u, 0.1) * exp(-abs(r - R * 1.1) / (px * 2.0)) * (0.4 + 0.8 * u.level);
    }
    return float4(col, 1.0);
}

// ================================================================ Aurora
// Real northern lights: draped curtains marched through altitude layers.
// Oxygen green, a pink lower fringe, red/violet tops; stars, mountains, a lake.

static float auroraCurtain(float2 p, float t) {
    float wob = fbm3(float2(p.x * 0.12 + t * 0.03, 1.7)) * 9.0 + fbm3(float2(p.x * 0.45 - t * 0.06, 4.2)) * 2.2;
    float d1 = abs(p.y - (4.2 + wob * 0.7));
    float wob2 = fbm3(float2(p.x * 0.1 - t * 0.02, 8.3)) * 10.0;
    float d2 = abs(p.y - (8.0 + wob2 * 0.8));
    float sheet = exp(-d1 * 1.8) + 0.55 * exp(-d2 * 1.3);
    // fine vertical rays drifting along the curtain, shimmering
    float r1 = gnoise(float2(p.x * 9.0 + wob * 0.8, t * 0.35));
    float r2 = gnoise(float2(p.x * 31.0 - wob * 1.3, t * 0.9));
    float rays = 0.18 + 0.82 * pow(r1, 2.6) * (0.55 + 0.45 * r2);
    float folds = 0.55 + 0.45 * sin(p.x * 0.8 + wob * 1.5 + t * 0.2);
    return sheet * rays * folds;
}
static float3 auroraColor(float h) {
    float3 pink = float3(1.0, 0.25, 0.55), green = float3(0.15, 1.0, 0.45), red = float3(0.85, 0.12, 0.35), violet = float3(0.45, 0.2, 0.9);
    float3 c = mix(pink, green, smoothstep(0.0, 0.08, h));
    return mix(c, mix(red, violet, 0.4), smoothstep(0.45, 1.0, h));
}
static float3 auroraSky(float3 rd, float t, float jitter, constant Uniforms &u, texture2d<float> specTex) {
    float3 c = mix(float3(0.012, 0.03, 0.05), float3(0.002, 0.004, 0.014), smoothstep(0.0, 0.55, rd.y));
    c += float3(0.02, 0.06, 0.05) * exp(-rd.y * 14.0);                         // airglow on the horizon
    // stars, denser along a faint band of the Milky Way
    float band = exp(-pow((rd.x * 0.8 - rd.y + 0.35) * 3.2, 2.0));
    c += float3(0.03, 0.03, 0.045) * band * fbm3(rd.xy * 9.0) * smoothstep(0.02, 0.2, rd.y);
    for (int l = 0; l < 2; l++) {
        float sc = l == 0 ? 220.0 : 480.0;
        float2 sp = rd.xz / max(rd.y + 0.15, 0.05) * sc;
        float2 id = floor(sp); float2 f = fract(sp) - 0.5;
        float h = hash2(id + float(l) * 17.0);
        float thr = l == 0 ? 0.985 : 0.975 - band * 0.05;
        float star = step(thr, h) * (1.0 - smoothstep(0.0, 0.08 + 0.06 * fract(h * 37.0), length(f))) * (0.6 + 0.4 * sin(u.time * (1.0 + h * 3.0) + h * 50.0));
        c += mix(float3(0.7, 0.8, 1.0), float3(1.0, 0.9, 0.75), fract(h * 13.0)) * star * (l == 0 ? 1.4 : 0.7);
    }
    float3 acc = float3(0.0);
    float energy = 0.6 + 0.9 * u.level + 0.7 * u.beat;
    for (int i = 0; i < 56; i++) {
        float fi = float(i) + jitter;
        float alt = 0.9 + fi * 0.06;
        float tt = alt / max(rd.y, 0.015);
        float2 p = rd.xz * tt * 0.9 + float2(0.0, 2.0);
        float d = auroraCurtain(p, t);
        float s = spec(specTex, fract(p.x * 0.05 + 0.5));
        // bright, sharp lower border fading upwards
        float prof = exp(-fi * 0.06) * (0.35 + 0.65 * smoothstep(0.0, 3.0, fi)) + 0.6 * exp(-fi * 0.5);
        acc += auroraColor(fi / 56.0) * d * prof * (0.55 + 0.9 * s);
    }
    c += acc * 0.6 * energy * smoothstep(0.0, 0.06, rd.y);
    return c;
}

fragment float4 auroraFragment(QuadOut in [[stage_in]],
                               constant Uniforms &u [[buffer(0)]],
                               texture2d<float> specTex [[texture(0)]]) {
    float2 uv = (fragCoord(in.position, u) - 0.5 * u.res) / u.res.y;
    float t = u.time * (0.6 + 0.4 * u.mid) + u.phase * 0.2;
    float jitter = hash2(floor(in.position.xy)) * 0.5;
    float3 rd = normalize(float3(uv.x, uv.y + 0.27, 1.0));
    float3 col;
    if (rd.y > 0.0) {
        col = auroraSky(rd, t, jitter, u, specTex);
    } else {
        float3 rr = float3(rd.x, -rd.y, rd.z);
        rr.x += 0.003 * sin(uv.y * 160.0 + u.time * 1.5) * (1.0 + u.bass * 2.0);
        col = auroraSky(rr, t, jitter, u, specTex) * 0.55 * smoothstep(-0.5, 0.0, rd.y) + float3(0.002, 0.004, 0.01);
    }
    float x = uv.x;
    float hy = -0.27;
    float px = 1.0 / u.res.y;
    float ridge = 0.012 + 0.05 * pow(gnoise(float2(x * 1.8, 0.0)), 1.5) + 0.018 * gnoise(float2(x * 7.0, 3.0)) + 0.006 * gnoise(float2(x * 25.0, 1.0)) + hy;
    // a line of pines along the far shore, in front of the mountains
    float cell = 0.018;
    float ci = floor(x / cell);
    float pine = hy;
    for (int k = -1; k <= 1; k++) {
        float id = ci + float(k);
        float h = hash1(id * 3.7);
        float cx = (id + 0.5 + (h - 0.5) * 0.6) * cell;
        float ht = 0.012 + 0.03 * fract(h * 17.0) * (0.4 + 0.6 * gnoise(float2(id * 0.15, 2.0)));
        float w = ht * 0.32;
        float top = hy + ht * (1.0 - abs(x - cx) / w);
        pine = max(pine, top);
    }
    float3 mountain = float3(0.007, 0.012, 0.02);
    float3 trees = float3(0.003, 0.005, 0.008);
    float m = (1.0 - smoothstep(ridge - px, ridge + px, uv.y)) * smoothstep(hy - px, hy + px, uv.y);
    col = mix(col, mountain + float3(0.01, 0.025, 0.02) * smoothstep(ridge - 0.03, ridge, uv.y), m);
    float tm = (1.0 - smoothstep(pine - px, pine + px, uv.y)) * smoothstep(hy - px, hy + px, uv.y);
    col = mix(col, trees, tm);
    float mirrorY = 2.0 * hy - uv.y;
    float mr = (1.0 - smoothstep(ridge - px, ridge + px, mirrorY)) * (1.0 - smoothstep(hy - px, hy + px, uv.y));
    col = mix(col, mountain * 0.7, mr * 0.9);
    float tr = (1.0 - smoothstep(pine - px, pine + px, mirrorY)) * (1.0 - smoothstep(hy - px, hy + px, uv.y));
    col = mix(col, trees, tr * 0.95);
    // ripples catching the light on the water
    if (uv.y < hy) {
        float rip = pow(gnoise(float2(uv.x * 6.0, uv.y * 220.0 + u.time * 0.8)), 6.0);
        col += col * rip * 1.5 * smoothstep(hy - 0.3, hy, uv.y);
    }
    return float4(col, 1.0);
}

// ================================================================ Silk
// Flowing satin folds in the artwork's colours, lit softly; beats send a sheen
// along the ridges.

static float silkHeight(float2 p, float t) {
    float2 q = p;
    q += 0.45 * float2(sin(q.y * 0.9 + t * 0.6), sin(q.x * 0.7 - t * 0.45));
    q += 0.15 * float2(sin(q.y * 2.3 - t * 0.9), sin(q.x * 1.9 + t * 0.7));
    float w = dot(q, float2(0.8, 0.6));
    float bend = 0.9 * sin(q.x * 1.3 - q.y * 0.9 + t * 0.8);
    return sin(w * 4.2 + bend + t * 0.5) * 0.45
         + sin(w * 1.9 - bend * 0.5 - t * 0.35 + q.y * 0.8) * 0.4
         + sin(w * 8.5 + bend * 1.6 + t) * 0.08;
}

static float4 silkScene(float2 fc, constant Uniforms &u, texture2d<float> specTex) {
    float2 p = (fc - 0.5 * u.res) / u.res.y;
    float t = u.time * 0.22 + u.phase * 0.035;
    float amp = 0.9 + 0.45 * u.bass;
    float2 sp = p * 3.2;
    float e = 0.002;
    float h = silkHeight(sp, t) * amp;
    float hx = silkHeight(sp + float2(e, 0.0), t) * amp;
    float hy = silkHeight(sp + float2(0.0, e), t) * amp;
    float3 n = normalize(float3(-(hx - h) / e * 0.3, -(hy - h) / e * 0.3, 1.0));
    float3 L = normalize(float3(-0.45, 0.65, 0.6));
    float3 V = float3(0.0, 0.0, 1.0);
    float diff = max(dot(n, L), 0.0);
    float3 H = normalize(L + V);
    float spc = pow(max(dot(n, H), 0.0), 45.0);
    float sheen = pow(1.0 - max(dot(n, V), 0.0), 2.0);
    float k = 0.5 + 0.5 * sin(p.x * 0.9 + p.y * 0.7 + h * 0.7 + t * 0.6);
    float3 base = mix(u.p2.rgb, u.p1.rgb, k);
    base = mix(base, u.p0.rgb, smoothstep(0.2, 1.0, h * 0.5 + 0.5) * 0.55);
    float shade = pow(0.5 + 0.5 * dot(n, L), 2.5);
    float3 col = base * (0.03 + 0.95 * shade);
    // satin: highlights stretched along the folds (Kajiya-Kay), a fine weave
    float3 T = normalize(float3(-(hy - h), hx - h, 0.0) + float3(1e-5, 0.0, 0.0));
    float th = dot(T, H);
    float weave = 0.85 + 0.15 * sin(fc.x * 1.7 + fc.y * 0.4) * sin(fc.y * 1.9 - fc.x * 0.3);
    float aniso = pow(sqrt(max(0.0, 1.0 - th * th)), 16.0) * weave * smoothstep(0.1, 0.6, diff);
    col += mix(float3(1.0), u.p0.rgb, 0.35) * (spc * 0.6 + aniso * 0.32) * (0.28 + 0.8 * u.level + 0.6 * u.beat);
    // a cool rim light from below and a faint iridescence at grazing angles
    float3 L2 = normalize(float3(0.6, -0.5, 0.45));
    col += mix(u.p2.rgb, float3(0.6, 0.75, 1.0), 0.5) * pow(max(dot(n, L2), 0.0), 3.0) * 0.12;
    col += u.p1.rgb * sheen * 0.24;
    col += (0.5 + 0.5 * cos(6.2831853 * (sheen * 1.6 + h * 0.2 + float3(0.0, 0.33, 0.67)))) * sheen * 0.08;
    col *= mix(0.22, 1.0, smoothstep(-1.1, 0.5, h));
    float s = spec(specTex, 0.1 + 0.6 * fract(p.x * 0.3 + 0.5));
    col += u.p0.rgb * exp(-abs(h - 0.55) * 18.0) * 0.08 * s;
    col *= 1.0 - 0.3 * dot(p, p);
    return float4(col, 1.0);
}

fragment float4 silkFragment(QuadOut in [[stage_in]],
                            constant Uniforms &u [[buffer(0)]],
                            texture2d<float> specTex [[texture(0)]]) {
    return silkScene(fragCoord(in.position, u), u, specTex);
}

// ================================================================ Waves
// A soft, flowing glow around the edges of the screen (in the spirit of a voice
// assistant listening) with translucent waveform lobes breathing in the centre.

static float3 glowStop(int i) {
    if (i == 0) return float3(0.74, 0.45, 1.00);
    if (i == 1) return float3(1.00, 0.55, 0.85);
    if (i == 2) return float3(0.45, 0.58, 1.00);
    if (i == 3) return float3(1.00, 0.36, 0.45);
    if (i == 4) return float3(1.00, 0.68, 0.36);
    return float3(0.80, 0.48, 1.00);
}
static float3 glowColor(float x) {
    x = fract(x) * 6.0;
    int i = int(floor(x));
    float f = smoothstep(0.0, 1.0, fract(x));
    return mix(glowStop(i), glowStop((i + 1) % 6), f);
}

static float4 wavesScene(float2 fc, constant Uniforms &u, texture2d<float> specTex) {
    float2 p = (fc - 0.5 * u.res) / u.res.y;
    float aspect = u.res.x / u.res.y;
    float t = u.time;
    float2 q = abs(p) - float2(0.5 * aspect, 0.5) + 0.05;
    float sd = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - 0.05;
    float d = max(-sd, 0.0);
    float ang = atan2(p.y, p.x / aspect);
    float a = ang / (2.0 * M_PI_F) + 0.5;
    float2 cs = float2(cos(ang), sin(ang));
    float n1 = gnoise(cs * 1.4 + float2(t * 0.30, -t * 0.23));
    float n2 = gnoise(cs * 2.6 + float2(-t * 0.50, t * 0.37) + 7.0);
    float n3 = gnoise(cs * 1.9 + float2(t * 0.17, t * 0.29) + 3.0);
    float s = spec(specTex, abs(fract(a + 0.25) * 2.0 - 1.0) * 0.75);
    float energy = 0.55 + 0.75 * u.level + 0.55 * s + 0.25 * u.beat;
    float w1 = (0.0035 + 0.006 * n1) * energy;
    float w2 = (0.016 + 0.030 * n2) * energy;
    float w3 = (0.05 + 0.07 * n3) * (0.65 + 0.6 * u.level);
    float3 col = float3(0.0);
    col += glowColor(a + t * 0.050) * exp(-d / w1) * 1.5;
    col += glowColor(a - t * 0.035 + 0.33) * exp(-d / w2) * 0.85;
    col += glowColor(a + t * 0.020 + 0.66) * exp(-d / w3) * 0.24;
    col += float3(1.0) * exp(-d / (w1 * 0.35)) * 0.12;
    // translucent lobes in the centre
    float x = p.x / (0.5 * aspect);
    for (int i = 0; i < 4; i++) {
        float fi = float(i);
        float cx = 0.42 * sin(t * (0.19 + fi * 0.06) + fi * 2.1);
        float wd = 0.30 + 0.12 * sin(t * 0.27 + fi * 1.3);
        float env = exp(-(x - cx) * (x - cx) / (wd * wd));
        float amp = (0.025 + 0.20 * spec(specTex, 0.06 + fi * 0.17) + 0.05 * u.beat) * env;
        float k = 4.0 + fi * 1.6;
        float y = amp * abs(sin(x * k + t * (0.9 + fi * 0.25) + fi * 1.7));
        float dy = abs(p.y) - y;
        float fill = 1.0 - smoothstep(-0.004, 0.012, dy);
        float edge = exp(-abs(dy) * 110.0);
        col += glowColor(fi * 0.21 + t * 0.02) * (fill * 0.22 + edge * 0.55) * env;
    }
    col += glowColor(0.1 + t * 0.02) * exp(-abs(p.y) * 260.0) * 0.18 * (1.0 - smoothstep(0.6, 1.0, abs(x)));
    col += glowColor(0.5 + t * 0.01) * 0.008;
    return float4(col, 1.0);
}

fragment float4 wavesFragment(QuadOut in [[stage_in]],
                            constant Uniforms &u [[buffer(0)]],
                            texture2d<float> specTex [[texture(0)]]) {
    return wavesScene(fragCoord(in.position, u), u, specTex);
}

// ================================================================ Calm
// The backdrop for Lyric Pop: a quiet dusk sky with slow mist in the artwork's
// colours and a few motes of light drifting upwards. It barely reacts, so the
// words stay the centre of attention.

static float4 calmScene(float2 fc, constant Uniforms &u, texture2d<float> specTex) {
    float2 p = (fc - 0.5 * u.res) / u.res.y;
    float aspect = u.res.x / u.res.y;
    float t = u.time * 0.035;
    float3 top = mix(u.shadow.rgb, u.p2.rgb, 0.22) * 0.55;
    float3 bot = mix(u.shadow.rgb, u.p1.rgb, 0.3) * 0.5;
    float3 col = mix(bot, top, smoothstep(-0.7, 0.6, p.y));
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float2 q = p * (1.1 + fi * 0.55) + float2(t * (1.0 + fi * 0.6), fi * 3.1);
        float n = fbm3(q + float2(fbm3(q * 0.7 + t), fbm3(q * 0.6 - t + 4.0)) * 1.4);
        col += pal(u, fi * 0.33 + 0.1) * smoothstep(0.42, 0.9, n) * (0.10 - fi * 0.022) * (0.9 + 0.25 * u.level);
    }
    col += pal(u, 0.05) * exp(-abs(p.y + 0.18) * 3.5) * 0.05 * (1.0 + 0.3 * u.bass);
    for (int i = 0; i < 26; i++) {
        float fi = float(i);
        float h1 = hash1(fi * 1.37), h2 = hash1(fi * 4.11), h3 = hash1(fi * 7.73);
        float y = fract(h2 + u.time * 0.008 * (0.4 + h3)) * 1.5 - 0.75;
        float x = (h1 - 0.5) * aspect + 0.03 * sin(u.time * 0.15 + fi);
        float r = 0.003 + 0.009 * h3;
        float d = length(p - float2(x, y));
        float tw = 0.55 + 0.45 * sin(u.time * (0.3 + h1 * 0.4) + fi * 2.0);
        col += mix(float3(1.0, 0.9, 0.8), pal(u, h1), 0.5) * exp(-d * d / (r * r)) * 0.3 * tw * smoothstep(0.75, 0.4, abs(y));
    }
    col *= 1.0 - 0.25 * dot(p, p);
    return float4(col, 1.0);
}

fragment float4 calmFragment(QuadOut in [[stage_in]],
                            constant Uniforms &u [[buffer(0)]],
                            texture2d<float> specTex [[texture(0)]]) {
    return calmScene(fragCoord(in.position, u), u, specTex);
}

// ================================================================ Night Drive
// First person from the driver's seat (right-hand drive, left lane) on a rainy
// evening: a lit street streams past through the windshield, out of focus,
// with wet-road reflections, traffic, wipers clearing the rain, street lights
// sweeping over the cabin, and a dashboard whose screen shows LED bars (the
// song title is drawn natively on top of the screen).

static float sdBox(float2 p, float2 b, float r) { float2 q = abs(p) - b + r; return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r; }

static float drvCurve(float z, float c) { return c * z * z; }
static float2 drvProject(float3 w, float c, float camX) {
    float x = w.x + drvCurve(w.z, c) - camX;
    return float2(x, w.y - 1.25) * 0.9 / w.z + float2(0.0, 0.03);
}
static float3 drvBokeh(float2 uv, float2 c, float r, float3 lc) {
    float d = length(uv - c);
    if (d > r * 5.0) return float3(0.0);
    float disc = 1.0 - smoothstep(r * 0.8, r, d);
    float rim = smoothstep(r * 0.55, r * 0.95, d) * disc;
    return lc * (disc * 0.45 + rim * 0.25 + exp(-d / (r * 1.5)) * 0.08);
}
static float3 drvStreak(float2 uv, float2 m, float r, float3 lc) {
    float dx = abs(uv.x - m.x) / (r * 0.9);
    if (dx > 3.0) return float3(0.0);
    float dy = uv.y - m.y;
    return lc * exp(-dx * dx) * exp(-abs(dy) / (dy < 0.0 ? 0.16 : 0.025)) * 0.3;
}

static float invSmooth(float y) { return 0.5 - sin(asin(clamp(1.0 - 2.0 * y, -1.0, 1.0)) / 3.0); }

// Wipers: returns seconds since the glass at `uv` was last wiped; `blade` gets
// the distance to the nearest blade.
static float drvWipe(float2 uv, float t, thread float &blade) {
    float T = 7.0;
    float cyc = fmod(t, T);
    float A0 = 0.06, A1 = 2.05;
    float ang = cyc < 0.6 ? mix(A0, A1, smoothstep(0.0, 1.0, cyc / 0.6))
              : (cyc < 0.7 ? A1 : (cyc < 1.3 ? mix(A1, A0, smoothstep(0.0, 1.0, (cyc - 0.7) / 0.6)) : A0));
    float since = 99.0;
    blade = 99.0;
    for (int k = 0; k < 2; k++) {
        float2 pv = float2(k == 0 ? -0.52 : 0.06, -0.09);
        float L = k == 0 ? 0.55 : 0.5;
        float2 d = uv - pv;
        float2 dir = float2(cos(ang), sin(ang));
        float al = clamp(dot(d, dir), 0.0, L);
        float bd = length(d - dir * al) - (al > L * 0.3 ? 0.0045 : 0.0025);
        blade = min(blade, bd);
        float rr = length(d);
        float a = atan2(d.y, d.x);
        if (rr < L && rr > 0.05 && a > A0 && a < A1) {
            float f = (a - A0) / (A1 - A0);
            float tu = 0.6 * invSmooth(f);
            float td = 0.7 + 0.6 * (1.0 - invSmooth(f));
            float s = cyc >= td ? cyc - td : (cyc >= tu ? cyc - tu : cyc + T - td);
            since = min(since, s);
        }
    }
    return since;
}

static float3 driveRain(float2 uv, float t, float since) {
    float2 off = float2(0.0);
    float mask = 0.0;
    float fill = clamp(since / 4.5, 0.0, 1.0);
    for (int l = 0; l < 2; l++) {
        float fl = float(l);
        float scale = 26.0 + fl * 22.0;
        float2 g = uv * float2(scale, scale * 0.8);
        float2 id = floor(g);
        float2 f = fract(g) - 0.5;
        float h = hash2(id + fl * 11.0);
        if (h > 0.45 && fract(h * 31.0) < fill) {
            float2 o = (float2(hash2(id + 1.7), hash2(id + 4.3)) - 0.5) * 0.36;   // drops stay inside their cell
            float r = 0.13 + 0.16 * fract(h * 17.0);
            float2 dp = (f - o) * float2(1.0, 1.15);
            float m = 1.0 - smoothstep(r * 0.8, r, length(dp));
            off += dp / r * 0.012 * m;
            mask = max(mask, m);
        }
    }
    float2 g = uv * float2(14.0, 1.0);
    float h = hash1(floor(g.x) * 3.1);
    float y = fract(-t * (0.08 + 0.12 * h) + h * 7.0) * 1.4 - 0.7;
    float x = (fract(g.x) - 0.5) / 14.0;
    float2 dp = float2(x + 0.004 * sin(uv.y * 40.0 + h * 10.0), (uv.y - y) * 0.9);
    float on = step(0.55, h) * step(1.5, since);
    float m = (1.0 - smoothstep(0.006, 0.009, length(dp * float2(1.0, 0.8)))) * on;
    off += dp / 0.009 * 0.012 * m;
    mask = max(mask, m);
    float trail = (1.0 - smoothstep(0.0015, 0.003, abs(x))) * smoothstep(y, y + 0.25, uv.y) * step(uv.y, y + 0.25) * on;
    return float3(off, max(mask, trail * 0.25));
}

// ================================================================ Night Drive (lofi)
// An aesthetic, painterly night drive: from the driver's seat of a Creta-like
// cabin, an endless road under a violet sky, a city glowing on the horizon,
// streetlights sweeping past with rain falling through their light, wet asphalt
// reflections, tail-lights ahead, drops on the glass and wipers. The cabin is
// soft and dark, lit by the screens' glow and the lamps going by.

#define LOFI_H 0.105
#define LOFI_CAMH 1.3
#define LOFI_F 1.0

static float2 lofiProject(float3 w, float c, float camX) {
    float x = w.x + c * w.z * w.z - camX;
    return float2(x, w.y - LOFI_CAMH) * LOFI_F / w.z + float2(0.0, LOFI_H);
}

static float3 lofiSky(float2 uv, float t, constant Uniforms &u) {
    float H = LOFI_H;
    float h = uv.y - H;
    float3 zenith = float3(0.030, 0.035, 0.10);
    float3 mid = float3(0.15, 0.10, 0.26);
    float3 horizon = float3(0.60, 0.28, 0.40);
    float3 col = mix(horizon, mid, smoothstep(0.0, 0.16, h));
    col = mix(col, zenith, smoothstep(0.12, 0.5, h));
    col = mix(col, col * (0.6 + 0.8 * u.p2.rgb), 0.15);
    // moon behind thin clouds
    float2 mp = float2(-0.40, 0.27);
    float md = length(uv - mp);
    float3 moon = float3(1.0, 0.93, 0.86);
    col += moon * exp(-md * 8.0) * 0.16;
    // clouds lit from below by the city, edges silvered by the moon
    float2 cp = float2(uv.x * 1.3 + t * 0.005, uv.y * 4.0);
    float n = fbm3(cp + float2(fbm3(cp * 0.7 + 3.1), fbm3(cp * 0.5 - 1.7)) * 0.7);
    float band = smoothstep(0.40, 0.72, n) * smoothstep(-0.01, 0.07, h) * (1.0 - smoothstep(0.30, 0.48, h));
    float3 cloudCol = mix(float3(0.45, 0.22, 0.36), float3(0.11, 0.08, 0.20), smoothstep(0.0, 0.25, h));
    float disc = 1.0 - smoothstep(0.025, 0.028, md);
    col = mix(col, moon * 0.95, disc * (1.0 - band * 0.7));
    col = mix(col, cloudCol, band * 0.88);
    col += moon * pow(max(0.0, 1.0 - md * 2.8), 4.0) * smoothstep(0.4, 0.6, n) * 0.35;
    // stars
    float2 sg = uv * 150.0;
    float hs = hash2(floor(sg));
    col += float3(0.85, 0.88, 1.0) * step(0.986, hs) * (1.0 - smoothstep(0.0, 0.3, length(fract(sg) - 0.5)))
         * smoothstep(0.14, 0.35, h) * (1.0 - band) * (0.4 + 0.3 * sin(t * 2.0 + hs * 40.0));
    return col;
}

static float3 lofiSkyline(float2 uv, float3 col, float scroll, constant Uniforms &u, texture2d<float> specTex) {
    float H = LOFI_H;
    for (int k = 2; k >= 0; k--) {          // far layer first
        float fk = float(k);
        float x = uv.x * (1.0 + fk * 0.6) + scroll * (0.15 + fk * 0.3) + fk * 7.3;
        float w = 0.03 + 0.018 * fk;
        float cell = floor(x / w);
        float hr = hash1(cell * 1.37 + fk * 5.1);
        float hgt = (0.012 + 0.05 * hr * hr) * (1.0 - fk * 0.2);
        if (hash1(cell * 3.7 + fk) > 0.9) hgt += 0.03;
        float top = H + hgt;
        float inB = (1.0 - smoothstep(top - 0.0015, top + 0.0015, uv.y)) * step(H - 0.012, uv.y);
        float fog = 0.55 + fk * 0.2;
        float3 bcol = mix(float3(0.04, 0.03, 0.09), col, fog * 0.8);
        float2 wg = float2((x / w - cell) * 7.0, (uv.y - H) * (520.0 + fk * 160.0));
        float2 wid = floor(wg);
        float lit = step(0.7, hash2(wid + cell * 13.0 + fk)) * step(0.3, fract(wg.x)) * step(0.35, fract(wg.y))
                  * step(0.5, wid.x) * step(wid.x, 5.5);
        float3 wcol = mix(float3(1.0, 0.70, 0.40), float3(0.70, 0.85, 1.0), step(0.72, hash1(cell + wid.y * 3.1)));
        bcol += wcol * lit * (0.25 + 0.3 * fk) * (0.8 + 0.5 * spec(specTex, 0.15 + 0.12 * fk));
        float tip = exp(-length((uv - float2((cell + 0.5) * w - scroll * (0.15 + fk * 0.3) - fk * 7.3, top + 0.004)) * float2(1.0 + fk * 0.6, 1.0)) * 900.0);
        bcol += float3(1.0, 0.2, 0.2) * tip * step(0.9, hash1(cell * 3.7 + fk)) * (0.5 + 0.5 * sin(scroll * 0.0 + u.time * 3.0 + cell));
        col = mix(col, bcol, inB);
    }
    col += float3(0.95, 0.45, 0.42) * exp(-abs(uv.y - H) * 40.0) * 0.16;
    return col;
}

/// Light from a streetlamp at screen point `head` falling as a soft cone to `ground`.
static float lofiCone(float2 uv, float2 head, float2 ground, float halfWidth) {
    float span = head.y - ground.y;
    if (span <= 0.0) return 0.0;
    float f = clamp((head.y - uv.y) / span, 0.0, 1.0);
    float inside = step(ground.y, uv.y) * step(uv.y, head.y);
    float cx = mix(head.x, ground.x, f);
    float w = max(halfWidth * f, 0.002);
    return inside * (1.0 - smoothstep(w * 0.6, w, abs(uv.x - cx))) * (1.0 - f * 0.55);
}

static float3 lofiOutside(float2 uv, float t, constant Uniforms &u, texture2d<float> specTex, thread float &pass) {
    float H = LOFI_H;
    float camH = LOFI_CAMH;
    float F = LOFI_F;
    float dist = t * 15.0;
    float c = 0.0011 * sin(t * 0.05) + 0.0005 * sin(t * 0.13 + 1.0);
    float camX = -1.8 + 0.08 * sin(t * 0.09);
    float scroll = c * 70.0;
    float3 col = lofiSky(uv, t, u);
    col = lofiSkyline(uv, col, scroll, u, specTex);
    float3 haze = float3(0.34, 0.18, 0.32);
    float3 lampCol = float3(1.0, 0.66, 0.36);
    float light = 0.0;                     // how lit the air is here (for the rain)
    float ground = 1.0 - smoothstep(H - 0.008, H + 0.002, uv.y);

    // the road
    if (uv.y < H) {
        float z = camH * F / max(H - uv.y, 1e-4);
        float xw = uv.x * z / F + camX - c * z * z;
        float zr = z + dist;
        float3 road = float3(0.028, 0.028, 0.045);
        road += haze * exp(-(H - uv.y) * 16.0) * 0.55;                         // sky glow on the wet surface
        road += (fbm3(float2(xw * 0.9, zr * 0.35)) - 0.5) * 0.018;
        float lw = 0.07 + z * 0.0014;
        float m = (1.0 - smoothstep(lw, lw * 2.6, abs(xw))) * step(fract(zr / 10.0), 0.42);
        m += (1.0 - smoothstep(lw, lw * 2.6, abs(abs(xw) - 3.6))) * 0.8;
        road += float3(0.9, 0.86, 0.78) * m * exp(-z * 0.022) * 0.32;
        // our headlights on the road ahead
        float beam = exp(-pow((xw - camX) / (1.2 + z * 0.06), 2.0)) * smoothstep(3.0, 8.0, z) * exp(-z * 0.045);
        road += float3(0.95, 0.9, 0.8) * beam * 0.22;
        light += beam;
        // pools under the lamps
        for (int k = 0; k < 6; k++) {
            float lz = (float(k) + 1.0) * 30.0 - fmod(dist, 30.0);
            for (int s = 0; s < 2; s++) {
                float sd = s == 0 ? -1.0 : 1.0;
                float lzz = lz + (sd > 0.0 ? 15.0 : 0.0);
                float pl = exp(-pow(xw - sd * 3.0, 2.0) * 0.06 - pow(z - lzz, 2.0) * 0.008);
                road += lampCol * pl * 0.2;
            }
        }
        float shoulder = smoothstep(4.0, 4.4, abs(xw));
        road = mix(road, float3(0.018, 0.02, 0.03), shoulder);
        col = mix(road, haze * 0.55, 1.0 - exp(-z * 0.011));
    }

    // guardrails with posts streaming past
    for (int s = 0; s < 2; s++) {
        float sd = s == 0 ? -1.0 : 1.0;
        float X = sd * 4.4;
        if ((uv.x - 0.0) * sd <= 0.0) continue;
        float z0 = (X - camX) * F / uv.x;
        if (z0 <= 1.5 || z0 > 220.0) continue;
        float z1 = (X - camX + c * z0 * z0) * F / uv.x;
        if (z1 <= 1.5) continue;
        float ylo = H + (0.45 - camH) * F / z1;
        float yhi = H + (0.80 - camH) * F / z1;
        float rail = smoothstep(ylo - 0.0015, ylo + 0.0015, uv.y) * (1.0 - smoothstep(yhi - 0.0015, yhi + 0.0015, uv.y));
        float sheen = 0.5 + 0.5 * sin((uv.y - ylo) / max(yhi - ylo, 1e-4) * 3.14159);
        float3 railCol = float3(0.035, 0.035, 0.055) + float3(0.10, 0.09, 0.14) * pow(sheen, 6.0) + haze * 0.06;
        float zr = z1 + dist;
        railCol += lampCol * exp(-pow(fract(zr / 30.0 + (sd > 0.0 ? 0.5 : 0.0)) - 0.5, 2.0) * 60.0) * 0.25;
        float reflector = (1.0 - smoothstep(0.0, 0.08, abs(fract(zr / 8.0) - 0.5))) * exp(-z1 * 0.03);
        railCol += float3(1.0, 0.55, 0.15) * reflector * 0.9;
        railCol = mix(railCol, haze * 0.55, 1.0 - exp(-z1 * 0.011));
        col = mix(col, railCol, rail);
        float post = (1.0 - smoothstep(0.03, 0.06, abs(fract(zr / 4.0) - 0.5))) * step(H + (0.0 - camH) * F / z1, uv.y) * step(uv.y, ylo);
        col = mix(col, float3(0.03, 0.03, 0.05), post * exp(-z1 * 0.02) * 0.9);
    }

    // streetlamps: poles, glowing heads, cones of light, reflections
    for (int k = 0; k < 6; k++) {
        float lz0 = (float(k) + 1.0) * 30.0 - fmod(dist, 30.0);
        for (int s = 0; s < 2; s++) {
            float sd = s == 0 ? -1.0 : 1.0;
            float lz = lz0 + (sd > 0.0 ? 15.0 : 0.0);
            if (lz < 1.6) continue;
            float poleX = sd * 5.0;
            float2 base = lofiProject(float3(poleX, 0.0, lz), c, camX);
            float2 top = lofiProject(float3(poleX, 8.8, lz), c, camX);
            float2 head = lofiProject(float3(sd * 3.4, 8.5, lz), c, camX);
            float pw = 0.0006 + 0.08 / lz;
            float pole = (1.0 - smoothstep(pw * 0.5, pw, abs(uv.x - base.x))) * step(base.y, uv.y) * step(uv.y, top.y);
            float2 pa = uv - top;
            float2 ba = head - top;
            float hh = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
            float arm = 1.0 - smoothstep(pw * 0.4, pw * 0.8, length(pa - ba * hh));
            float fogz = exp(-lz * 0.01);
            col = mix(col, float3(0.02, 0.02, 0.035), max(pole, arm) * fogz * 0.95);
            float hd = length((uv - head) * float2(1.0, 1.6));
            float r = 0.004 + 0.12 / lz;
            float glow = (exp(-hd / (r * 0.3)) * 2.0 + exp(-hd / (r * 1.6)) * 0.5 + exp(-hd / (r * 5.0)) * 0.12) * (0.9 + 0.35 * u.bass);
            col += lampCol * glow * fogz;
            col += lampCol * exp(-abs(uv.y - head.y) * 500.0) * exp(-abs(uv.x - head.x) / (r * 7.0)) * 0.18 * fogz;   // anamorphic streak
            col += lampCol * exp(-abs(uv.x - head.x) * 500.0) * exp(-abs(uv.y - head.y) / (r * 4.0)) * 0.08 * fogz;
            float2 g = lofiProject(float3(sd * 3.0, 0.0, lz), c, camX);
            float cone = lofiCone(uv, head, g, 3.2 * 0.95 / lz);
            col += lampCol * cone * 0.05 * fogz;
            light += cone * fogz;
            col += drvStreak(uv, lofiProject(float3(sd * 3.4, -8.5, lz), c, camX), r * 0.9, lampCol * 0.9) * ground;
            pass += exp(-lz * 0.18);
        }
    }

    // the car ahead
    float zc = 22.0 + 4.0 * sin(t * 0.13);
    float xc = -1.8 + 0.2 * sin(t * 0.1);
    float2 cpos = lofiProject(float3(xc, 0.75, zc), c, camX);
    float sc = 0.95 / zc;
    float body = sdBox(uv - cpos, float2(0.92, 0.5) * sc, 0.3 * sc);
    float roof = sdBox(uv - cpos - float2(0.0, 0.62) * sc, float2(0.66, 0.28) * sc, 0.22 * sc);
    col = mix(col, float3(0.02, 0.02, 0.035), (1.0 - smoothstep(-0.004, 0.006, min(body, roof))) * 0.92);
    float brake = 0.8 + 1.2 * u.bass + 0.6 * u.beat;
    for (int s = 0; s < 2; s++) {
        float sd = s == 0 ? -1.0 : 1.0;
        float3 w = float3(xc + sd * 0.68, 0.9, zc);
        float r = 0.006 + 0.16 / zc;
        float3 tl = float3(1.0, 0.12, 0.10) * brake;
        col += drvBokeh(uv, lofiProject(w, c, camX), r, tl);
        col += drvStreak(uv, lofiProject(float3(w.x, -w.y, w.z), c, camX), r, tl) * ground;
    }
    // oncoming traffic now and then
    for (int i = 0; i < 2; i++) {
        float fi = float(i);
        float zo = 170.0 - fmod(t * 34.0 + fi * 85.0, 170.0);
        if (zo < 2.0) continue;
        float boost = 1.0 + 6.0 / zo;
        for (int s = 0; s < 2; s++) {
            float3 w = float3(1.8 + (float(s) * 2.0 - 1.0) * 0.7, 0.7, zo);
            float2 sp = lofiProject(w, c, camX);
            float r = 0.006 + 0.18 / zo;
            float3 lc = float3(0.9, 0.93, 1.0) * boost;
            col += drvBokeh(uv, sp, r, lc);
            col += drvStreak(uv, lofiProject(float3(w.x, -w.y, w.z), c, camX), r, lc) * ground;
            col += lc * exp(-abs(uv.y - sp.y) * 300.0) * exp(-abs(uv.x - sp.x) * 3.5) * 0.05 * min(boost, 3.0);
            light += exp(-length(uv - sp) / (r * 8.0)) * min(boost, 3.0) * 0.5;
        }
        pass += exp(-zo * 0.12) * 0.5;
    }

    // rain falling through the light
    float2 rg = float2(uv.x * 95.0 + uv.y * 16.0, uv.y * 6.0 + t * 7.5);
    float rid = floor(rg.x);
    float rh = hash1(rid * 1.31);
    float ry = fract(rg.y + rh * 13.0);
    float streak = (1.0 - smoothstep(0.0, 0.12, abs(fract(rg.x) - 0.5))) * smoothstep(0.0, 0.1, ry) * (1.0 - smoothstep(0.1, 0.32, ry)) * step(0.55, rh);
    col += float3(0.85, 0.85, 1.0) * streak * (0.02 + 0.5 * min(light, 1.5));
    return col;
}

static float4 lofiScene(float2 fc, constant Uniforms &u, texture2d<float> specTex) {
    float2 uv = (fc - 0.5 * u.res) / u.res.y;
    float aspect = u.res.x / u.res.y;
    float t = u.time;
    float px = 1.0 / u.res.y;
    #define AA(d) clamp(0.5 - (d) / px, 0.0, 1.0)
    #define SOFT(d, w) (1.0 - smoothstep(-(w), (w), (d)))
    float2 sway = float2(0.0025 * sin(t * 0.8), 0.001 * sin(t * 6.1) * (0.4 + u.bass) + 0.0012 * sin(t * 1.5));
    float blade;
    float since = drvWipe(uv, t, blade);
    float3 r = driveRain(uv, t, since);
    float pass = 0.0;
    float dummy = 0.0;
    float3 view = lofiOutside(uv + sway + r.xy * 2.5, t, u, specTex, pass);
    if (r.z > 0.01) {
        float3 sharp = lofiOutside(uv + sway - r.xy * 5.0, t, u, specTex, dummy);
        view = mix(view, sharp * 1.15 + 0.02, r.z * 0.75);
    }
    float3 col = view * (0.9 + 0.1 * (1.0 - r.z));
    col = mix(col, float3(0.01, 0.01, 0.02), AA(blade) * 0.95);

    float clX = min(0.42, 0.5 * aspect - 0.24);
    float infoX = clX - 0.405;
    float3 cool = float3(0.32, 0.55, 1.0);                      // screen glow
    float3 warm = float3(1.0, 0.62, 0.34) * min(pass, 2.0);      // passing lamps
    float3 amber = float3(1.0, 0.55, 0.2);
    float3 dark = float3(0.024, 0.026, 0.045);
    float sweep = 0.5 + 0.5 * sin(t * 2.0);                      // light band travelling across the cabin

    // the screens' glow reflected faintly in the windshield
    float dashY = -0.03 - 0.022 * uv.x * uv.x;
    col += cool * exp(-max(uv.y - dashY, 0.0) * 22.0) * exp(-pow((uv.x - (infoX + clX) * 0.5) / 0.45, 2.0)) * 0.05;

    // roof and A-pillars: soft, dark, edges catching a little light
    float roofY = 0.37 - 0.05 * uv.x * uv.x;
    float roof = smoothstep(roofY - 0.006, roofY + 0.006, uv.y);
    col = mix(col, dark * 1.2 + warm * 0.02 + float3(0.03, 0.025, 0.05) * smoothstep(0.5, roofY, uv.y), roof);
    for (int sgn = -1; sgn <= 1; sgn += 2) {
        float sx = float(sgn);
        float edge = 0.5 * aspect - 0.1 - (0.37 - uv.y) * 0.3;
        float d = sx * uv.x - edge;
        col = mix(col, dark + warm * 0.03 * smoothstep(0.0, 0.08, d), smoothstep(-0.006, 0.006, d));
        col += (cool * 0.3 + warm * 0.5) * exp(-abs(d) * 260.0) * 0.12 * step(uv.y, roofY);
    }
    // rear-view mirror with a little charm swinging from it
    float2 mc = float2(0.0, 0.29);
    float mirror = sdBox(uv - mc, float2(0.15, 0.038), 0.034);
    col = mix(col, dark * 1.3, AA(sdBox(uv - float2(0.0, 0.345), float2(0.01, 0.03), 0.004)));
    if (mirror < 0.02) {
        float3 behind = mix(float3(0.05, 0.04, 0.1), float3(0.5, 0.25, 0.35), smoothstep(0.32, 0.26, uv.y)) * 0.5;
        behind += float3(1.0, 0.66, 0.36) * exp(-length(uv - float2(0.05 * sin(t * 0.7), 0.29)) * 60.0) * 0.4;
        col = mix(col, mix(dark, behind, step(mirror, -0.006)), SOFT(mirror, 0.0015));
        col += float3(0.6, 0.6, 0.8) * exp(-abs(mirror + 0.003) * 400.0) * 0.08;
    }
    // ---- the cabin: a 2024-25 Hyundai Creta (India, right-hand drive) at night ----
    // Modelled on interior photos: a dark charcoal dash top, a light greige
    // fascia band on the passenger side holding a long vent, the black glass
    // panel with both 10.25" screens, a copper line along its foot, the slim
    // chrome-slatted centre vent, the piano-black climate panel (chrome knobs,
    // blue LCD), and the light-grey four-spoke wheel: a big round airbag hub
    // with the chrome badge, black button panels with chrome toggles, and
    // satin-silver lower spokes that drop and bend out to the rim.
    float3 skyFill = float3(0.30, 0.24, 0.42);
    float3 light = skyFill * 0.55 + warm * 0.6 + float3(0.09);
    float3 greige = float3(0.66, 0.62, 0.57) * light;
    float3 charcoal = float3(0.11, 0.11, 0.12) * light;
    float3 darkGrey = float3(0.17, 0.17, 0.19) * light;
    float3 piano = float3(0.010, 0.010, 0.016);
    float3 copper = float3(0.85, 0.48, 0.26);
    float3 chromeLo = float3(0.09, 0.09, 0.12);
    float3 chromeHi = float3(0.78, 0.78, 0.86) * (0.45 + 0.55 * min(pass, 1.5)) + cool * 0.15;
    float2 hc = float2((infoX + clX) * 0.5, -0.115);
    float2 hh = float2((clX - infoX) * 0.5 + 0.215, 0.077);
    float house = sdBox(uv - hc, hh, 0.014);
    float panelLeft = hc.x - hh.x;
    float panelRight = hc.x + hh.x;
    float copperY = -0.2;

    // dash top: dark charcoal, its lip catching the sky and the lamps
    float dash = smoothstep(dashY + 0.003, dashY - 0.003, uv.y);
    float3 dashCol = charcoal * mix(0.7, 1.15, smoothstep(dashY - 0.06, dashY - 0.004, uv.y));
    dashCol += (skyFill * 0.25 + warm * 0.35) * exp(-max(dashY - uv.y, 0.0) * 120.0) * 0.35;
    dashCol += cool * exp(-max(house, 0.0) * 10.0) * 0.05;
    // light greige fascia band: passenger side (left of the panel) and by the door (right)
    float fasciaTop = -0.072 - 0.01 * uv.x * uv.x;
    float fasciaBot = copperY + 0.004;
    float fascia = smoothstep(fasciaTop + 0.003, fasciaTop - 0.003, uv.y) * smoothstep(fasciaBot - 0.003, fasciaBot + 0.003, uv.y);
    float3 fasciaCol = greige * mix(1.05, 0.75, smoothstep(fasciaTop, fasciaBot, uv.y));
    fasciaCol *= 1.0 + 0.04 * (fbm3(uv * 80.0) - 0.5);
    fasciaCol += warm * 0.12 * exp(-pow((uv.x - mix(-0.9, 0.9, sweep)) * 1.8, 2.0));
    fasciaCol += greige * 0.25 * exp(-abs(uv.y - fasciaTop) * 160.0);                 // the rounded top edge
    dashCol = mix(dashCol, fasciaCol, fascia);
    // dark lower dash beneath the copper line
    float lower = smoothstep(copperY + 0.002, copperY - 0.002, uv.y);
    float3 lowerCol = darkGrey * mix(0.95, 0.5, smoothstep(copperY, copperY - 0.22, uv.y)) + cool * exp(-max(house, 0.0) * 12.0) * 0.02;
    lowerCol *= 1.0 - 0.3 * exp(-max(copperY - uv.y, 0.0) * 45.0);                      // shade under the ledge
    dashCol = mix(dashCol, lowerCol, lower);
    // the copper line, door to door
    float cop = exp(-pow((uv.y - copperY) / 0.0026, 2.0));
    dashCol = mix(dashCol, copper * (0.5 + 0.4 * u.level + 0.25 * u.beat) + warm * 0.2, cop);
    dashCol += copper * exp(-abs(uv.y - copperY) * 80.0) * 0.05 * (0.6 + u.level);
    col = mix(col, dashCol, dash);

    // the long passenger-side vent in the fascia
    float pvRight = panelLeft - 0.03;
    float2 pvc = float2((-0.5 * aspect + 0.04 + pvRight) * 0.5, -0.118);
    float pv = sdBox(uv - pvc, float2((pvRight - (-0.5 * aspect + 0.04)) * 0.5, 0.018), 0.009);
    {
        float sl = smoothstep(0.3, 0.7, 0.5 + 0.5 * sin((uv.y - pvc.y) * 540.0));
        float3 vcol = mix(piano, charcoal * 0.8, sl * 0.6) + skyFill * 0.03 * smoothstep(pvc.y - 0.02, pvc.y + 0.02, uv.y);
        col = mix(col, vcol, SOFT(pv, 0.0016));
        col += chromeHi * exp(-abs(pv + 0.001) * 700.0) * 0.14;
        col += chromeHi * exp(-abs(uv.y - pvc.y) * 900.0) * step(pv, 0.0) * 0.1;      // the chrome blade across it
    }
    // square corner vent on the driver's side, and the greige door panel beyond
    float2 dvc = float2(min(panelRight + 0.1, 0.5 * aspect - 0.08), -0.1);
    if (dvc.x < 0.5 * aspect - 0.03) {
        float dv = sdBox(uv - dvc, float2(0.042, 0.03), 0.012);
        float sl = smoothstep(0.3, 0.7, 0.5 + 0.5 * sin((uv.y - dvc.y) * 420.0));
        col = mix(col, mix(piano, charcoal * 0.8, sl * 0.6), SOFT(dv, 0.0016));
        col += chromeHi * exp(-abs(dv + 0.001) * 600.0) * 0.2;
    }
    // the black glass panel holding both screens
    {
        float3 glass = piano + skyFill * 0.08 * exp(-abs(uv.y - (hc.y + hh.y - 0.008)) * 90.0);
        col = mix(col, glass, SOFT(house, 0.0016));
        col += float3(0.6, 0.62, 0.75) * exp(-abs(house + 0.001) * 520.0) * 0.08;
    }
    // infotainment screen: LED bars under the song (text drawn natively)
    float2 ic = float2(infoX, -0.115);
    float2 ih = float2(0.19, 0.066);
    float info = sdBox(uv - ic, ih, 0.007);
    if (info < 0.002) {
        float2 q = (uv - ic) / ih;
        float3 sbg = mix(float3(0.03, 0.045, 0.11), float3(0.07, 0.05, 0.13), q.y * 0.5 + 0.5);
        sbg += u.p1.rgb * 0.06 * (1.0 - length(q * float2(0.6, 1.0)));
        float bars = 22.0;
        float bx = (q.x * 0.5 + 0.5) * bars;
        float v = spec(specTex, floor(bx) / bars * 0.9);
        float barTop = -0.9 + v * 0.95;
        float colBar = step(0.18, fract(bx)) * step(fract(bx), 0.82) * step(-0.9, q.y);
        float3 barCol = mix(float3(0.3, 0.9, 1.0), u.p0.rgb, smoothstep(-0.9, 0.0, q.y));
        sbg += barCol * colBar * step(q.y, barTop) * 0.85 + barCol * colBar * exp(-max(q.y - barTop, 0.0) * 30.0) * 0.12;
        col = mix(col, sbg, SOFT(info, 0.0014));
    }
    // cluster: two round pale-blue dials with bright rims
    float2 cc = float2(clX, -0.115);
    float clu = sdBox(uv - cc, ih, 0.007);
    if (clu < 0.002) {
        float3 cbg = mix(float3(0.006, 0.012, 0.03), float3(0.012, 0.025, 0.055), (uv.y - cc.y) / ih.y * 0.5 + 0.5);
        for (int k = 0; k < 2; k++) {
            float sx = k == 0 ? -1.0 : 1.0;
            float2 gc = cc + float2(sx * 0.118, 0.0);
            float2 gd = uv - gc;
            float gr = length(gd);
            float R = 0.056;
            float ga = atan2(gd.x, gd.y);
            float face = 1.0 - smoothstep(R - 0.0025, R, gr);
            float3 fcol = mix(float3(0.07, 0.14, 0.26), float3(0.38, 0.6, 0.86), smoothstep(R * 0.3, R, gr));
            cbg = mix(cbg, fcol, face);
            cbg += float3(0.75, 0.88, 1.0) * exp(-pow((gr - R) / 0.0018, 2.0)) * 0.9;
            float inArc = step(-2.3, ga) * step(ga, 2.3);
            float ticks = step(0.8, fract((ga + 2.3) / 4.6 * 12.0)) * inArc * exp(-pow((gr - R * 0.85) / 0.004, 2.0));
            cbg += float3(1.0) * ticks * 0.8;
            float val = k == 0 ? 0.32 + 0.03 * sin(t * 0.07) + 0.03 * u.level : 0.24 + 0.45 * u.bass;
            float needle = val * 4.6 - 2.3;
            float2 nd = float2(sin(needle), cos(needle));
            float al = dot(gd, nd);
            float across = abs(dot(gd, float2(nd.y, -nd.x)));
            cbg = mix(cbg, float3(1.0, 0.4, 0.2) * 1.3, (1.0 - smoothstep(0.0012, 0.0028, across)) * step(-0.006, al) * step(al, R * 0.9));
            cbg = mix(cbg, float3(0.05, 0.06, 0.08), 1.0 - smoothstep(0.006, 0.008, gr));
        }
        col = mix(col, cbg, SOFT(clu, 0.0014));
    }
    // centre vent under the screen: chrome slats and two chrome tabs
    float2 vc = float2(infoX, -0.235);
    float vent = sdBox(uv - vc, float2(0.2, 0.018), 0.007);
    {
        float sl = smoothstep(0.35, 0.65, 0.5 + 0.5 * sin((uv.y - vc.y) * 480.0));
        col = mix(col, mix(piano, chromeLo * 1.4 + chromeHi * 0.08, sl), SOFT(vent, 0.0016));
        col += chromeHi * exp(-abs(vent + 0.001) * 650.0) * 0.14;
        for (int k = 0; k < 2; k++) {
            float tab = sdBox(uv - vc - float2((float(k) * 2.0 - 1.0) * 0.07, 0.003), float2(0.02, 0.0045), 0.0045);
            col = mix(col, mix(chromeLo, chromeHi, smoothstep(-0.004, 0.004, uv.y - vc.y)), SOFT(tab, 0.0012));
        }
    }
    // piano-black climate and media panel
    float2 pc = float2(infoX, -0.31);
    float panel = sdBox(uv - pc, float2(0.17, 0.052), 0.009);
    if (panel < 0.004) {
        float3 pcol = piano + skyFill * 0.05 * exp(-abs(uv.y - (pc.y + 0.046)) * 120.0) + warm * 0.02;
        for (int k = 0; k < 8; k++) {
            float2 bc = pc + float2(-0.1435 + float(k) * 0.041, 0.034);
            pcol = mix(pcol, float3(0.025, 0.025, 0.035), SOFT(sdBox(uv - bc, float2(0.0185, 0.009), 0.002), 0.001));
            pcol += float3(0.85, 0.88, 0.95) * exp(-abs(uv.y - bc.y) * 900.0) * step(abs(uv.x - bc.x), 0.008) * 0.3;
        }
        pcol += float3(1.0, 0.15, 0.1) * exp(-length((uv - pc - float2(0.0205, 0.034)) / float2(0.006, 0.004))) * 0.5;
        float lcd = sdBox(uv - pc - float2(0.0, 0.004), float2(0.08, 0.012), 0.002);
        pcol = mix(pcol, float3(0.06, 0.18, 0.5) + float3(0.25, 0.45, 0.8) * step(0.55, fract((uv.x - pc.x) * 110.0)) * step(abs(uv.y - pc.y - 0.004), 0.006) * 0.5, SOFT(lcd, 0.001));
        pcol += float3(0.2, 0.4, 0.9) * exp(-max(lcd, 0.0) * 120.0) * 0.08;
        for (int k = 0; k < 2; k++) {
            float2 kc = pc + float2((float(k) * 2.0 - 1.0) * 0.125, 0.004);
            float2 kq = uv - kc;
            float kd = length(kq);
            float3 knob = mix(chromeLo, chromeHi, smoothstep(-0.012, 0.012, kq.y + kq.x * 0.3));
            knob *= 0.85 + 0.15 * sin(atan2(kq.y, kq.x) * 40.0);
            pcol = mix(pcol, knob, 1.0 - smoothstep(0.012, 0.0145, kd));
            pcol = mix(pcol, float3(0.03), 1.0 - smoothstep(0.006, 0.008, kd));
        }
        for (int k = 0; k < 2; k++) {
            float2 tc = pc + float2((float(k) * 2.0 - 1.0) * 0.125, -0.03);
            pcol = mix(pcol, mix(chromeLo, chromeHi, smoothstep(-0.006, 0.006, (uv - tc).y)), SOFT(sdBox(uv - tc, float2(0.022, 0.006), 0.006), 0.001));
        }
        col = mix(col, pcol, SOFT(panel, 0.0016));
    }

    // ---- steering wheel ----
    float2 wc = float2(clX, -0.40);
    float steer = -(0.0011 * sin(t * 0.05) + 0.0005 * sin(t * 0.13 + 1.0)) * 110.0;
    float2 wq = rot(steer) * (uv - wc);
    float wr = length(wq);
    float WR = 0.355;
    float WT = 0.03;
    float3 leatherBase = float3(0.56, 0.54, 0.53) * light;          // light grey leather
    // indicator and wiper stalks behind the wheel
    for (int sgn = -1; sgn <= 1; sgn += 2) {
        float sx = float(sgn);
        float stalk = sdBox(uv - wc - float2(sx * 0.24, 0.035), float2(0.075, 0.011), 0.011);
        col = mix(col, float3(0.02, 0.02, 0.028) + warm * 0.02, SOFT(stalk, 0.0015));
        col += chromeHi * exp(-abs(stalk + 0.002) * 600.0) * 0.06;
    }
    // rim: a padded leather tube, lit from above, warm when a lamp passes
    float ring = abs(wr - WR) - WT;
    if (ring < 0.01) {
        float kr = clamp((wr - WR) / WT, -1.0, 1.0);
        float2 radial = wq / max(wr, 1e-4);
        float3 n = normalize(float3(radial * kr, sqrt(max(0.0, 1.0 - kr * kr))));
        float key = max(0.0, dot(n, normalize(float3(-0.3, 0.8, 0.55))));
        float rimWarm = pow(max(0.0, dot(n, normalize(float3(0.7, 0.4, 0.4)))), 3.0);
        float3 leather = leatherBase * (0.35 + 0.75 * key) + warm * rimWarm * 0.22 + cool * pow(key, 8.0) * 0.08;
        leather *= 1.0 + 0.05 * (hash2(floor(wq * 700.0)) - 0.5);
        // stitching around the inner edge
        leather *= 1.0 - 0.25 * step(0.5, fract(atan2(wq.y, wq.x) * 50.0)) * exp(-pow((wr - (WR - WT * 0.55)) / 0.0015, 2.0));
        col = mix(col, leather, SOFT(ring, 0.0015));
    }
    // horizontal spokes (leather) carrying the black button panels
    float spokeL = sdBox(wq - float2(-0.215, 0.0), float2(0.13, 0.036), 0.02);
    float spokeR = sdBox(wq - float2(0.215, 0.0), float2(0.13, 0.036), 0.02);
    float3 spokeCol = leatherBase * (0.6 + 0.4 * smoothstep(-0.04, 0.04, wq.y));
    col = mix(col, spokeCol, SOFT(min(spokeL, spokeR), 0.0015));
    // satin-silver lower spokes: drop from under the hub, then bend out to the rim
    for (int sgn = -1; sgn <= 1; sgn += 2) {
        float sx = float(sgn);
        float2 p0 = float2(sx * 0.07, -0.05);
        float2 p1 = float2(sx * 0.125, -0.165);
        float2 p2 = float2(sx * 0.29, -0.205);
        float dmin = 1e3;
        float side = 0.0;
        for (int sgi = 0; sgi < 2; sgi++) {
            float2 a = sgi == 0 ? p0 : p1;
            float2 b = sgi == 0 ? p1 : p2;
            float2 pa = wq - a;
            float2 ba = b - a;
            float hk = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
            float2 off = pa - ba * hk;
            float d = length(off);
            if (d < dmin) { dmin = d; side = dot(off, normalize(float2(-ba.y, ba.x))) * sx; }
        }
        float arm = dmin - 0.0155;
        float3 satin = mix(chromeLo * 1.2, chromeHi * 0.95, smoothstep(-0.012, 0.012, -side)) + greige * 0.15;
        col = mix(col, satin, SOFT(arm, 0.0013));
        col += chromeHi * exp(-pow((dmin - 0.009) / 0.0018, 2.0)) * step(side, 0.0) * 0.25;
    }
    // black button panels with a chrome toggle bar in each
    for (int sgn = -1; sgn <= 1; sgn += 2) {
        float sx = float(sgn);
        float2 q = wq - float2(sx * 0.155, 0.006);
        q.y += q.x * sx * 0.06;                                  // panels widen towards the rim
        float pod = sdBox(q, float2(0.072, 0.03 + max(0.0, q.x * sx) * 0.08), 0.012);
        col = mix(col, piano + skyFill * 0.06 * smoothstep(-0.03, 0.03, q.y) + warm * 0.02, SOFT(pod, 0.0012));
        col += chromeHi * exp(-abs(pod) * 700.0) * 0.1;
        float toggle = sdBox(q - float2(sx * 0.005, 0.0), float2(0.03, 0.0045), 0.0045);
        col = mix(col, mix(chromeLo, chromeHi, smoothstep(-0.004, 0.004, q.y)), SOFT(toggle, 0.001));
        for (int b = 0; b < 6; b++) {
            float bxp = sx * (-0.045 + float(b % 3) * 0.045);
            float byp = (b < 3) ? 0.019 : -0.019;
            col += float3(0.8, 0.85, 0.95) * exp(-abs(sdBox(q - float2(bxp, byp), float2(0.016, 0.007), 0.003)) * 900.0) * 0.18;
        }
    }
    // the big round airbag hub, softly domed, with the chrome badge
    float hub = sdBox(wq - float2(0.0, -0.012), float2(0.088, 0.08), 0.075);
    float3 hubCol = leatherBase * (0.45 + 0.7 * smoothstep(0.09, -0.06, length(wq - float2(-0.03, 0.03)))) + warm * 0.04;
    col = mix(col, hubCol, SOFT(hub, 0.0015));
    col *= 1.0 - 0.25 * exp(-abs(hub) * 260.0) * step(0.0, -hub) * 0.0;
    col += float3(0.0) * hub;
    float emb = abs(length((wq - float2(0.0, -0.002)) / float2(1.0, 0.52)) - 0.03) - 0.0026;
    float2 hq = rot(0.32) * (wq - float2(0.0, -0.002));
    float hBadge = min(min(sdBox(hq - float2(-0.008, 0.0), float2(0.0028, 0.011), 0.001),
                           sdBox(hq - float2(0.008, 0.0), float2(0.0028, 0.011), 0.001)),
                       sdBox(hq, float2(0.009, 0.0022), 0.001));
    col = mix(col, mix(chromeLo, chromeHi, smoothstep(-0.015, 0.015, wq.y + 0.01)), SOFT(min(emb, hBadge), 0.0011) * 0.95);

    float swing = 0.28 * sin(t * 1.6) + 0.12 * sin(t * 2.9 + 1.0) + 0.1 * u.beat;
    float2 hook = float2(0.06, 0.252);
    float2 dir = float2(sin(swing), -cos(swing));
    float2 charm = hook + dir * 0.095;
    float2 sp = uv - hook;
    float sh = clamp(dot(sp, dir), 0.0, 0.095);
    col = mix(col, float3(0.5, 0.45, 0.55) * 0.4, (1.0 - smoothstep(0.0006, 0.0014, length(sp - dir * sh))) * 0.8);
    // a glossy ornament with a little tassel, catching the light
    float cd = length(uv - charm);
    float3 charmCol = mix(u.p0.rgb, float3(1.0, 0.55, 0.65), 0.4);
    float2 tdir = float2(dir.x * 0.6, dir.y);
    for (int k = -1; k <= 1; k++) {
        float2 ta = charm + dir * 0.016;
        float2 tb = ta + normalize(tdir + float2(float(k) * 0.12, 0.0)) * 0.03;
        float2 pa = uv - ta;
        float2 ba = tb - ta;
        float hk = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
        col = mix(col, charmCol * 0.5, (1.0 - smoothstep(0.0008, 0.0018, length(pa - ba * hk))) * 0.9);
    }
    col = mix(col, float3(0.02, 0.015, 0.03), 1.0 - smoothstep(0.0175, 0.0195, cd));
    float3 ball = charmCol * (0.35 + 0.65 * smoothstep(0.02, -0.01, dot(uv - charm, float2(0.6, -0.8)))) * (0.8 + 0.4 * u.level);
    col = mix(col, ball, 1.0 - smoothstep(0.0155, 0.0175, cd));
    col += charmCol * exp(-cd * 45.0) * (0.10 + 0.3 * u.beat);
    col += float3(1.0) * exp(-length(uv - charm - float2(-0.005, 0.006)) * 700.0) * 0.7;

    // a soft vignette inside the cabin keeps the eye on the road
    col *= 1.0 - 0.25 * smoothstep(0.3, 0.9, length(uv * float2(0.7, 1.0)));
    #undef AA
    #undef SOFT
    return float4(col, 1.0);
}

// ================================================================ Night Drive (painted Creta)
// The painted cabin of a 2024-25 Creta (Resources/NightDrive) with the world
// outside rendered live behind its glass (see "the world outside" below):
// rain gathers on the windshield and the wipers sweep it, the warm light of
// each street lamp going by washes over the cabin, and the screens show the
// song and the speed. All maths is in the painting's pixel space.

#define PD_W 1920.0
#define PD_H 1080.0

static float3 pdUntonemap(float3 v) {
    float3 y = clamp(pow(clamp(v, 0.0, 1.0), float3(1.12)), 0.0, 0.975);
    float3 a = 2.51 - 2.43 * y;
    float3 b = 0.03 - 0.59 * y;
    float3 c = -0.14 * y;
    return (-b + sqrt(b * b - 4.0 * a * c)) / (2.0 * a);
}

// ================================================================ Night Drive (the world outside)
// An endless drive along a lake road at night, rendered live in the style of a
// painted anime background: a starry sky with a full moon and moonlit clouds,
// layered blue mountains with mist lying in the valleys, a still lake holding
// the lights of the far shore, a gently winding two-lane road with white posts,
// a hillside on the left under broadleaf trees that glow gold where the street
// lamps reach them. Everything stands in metres and is projected, so the near
// world streams past with true parallax while the mountains barely move.
// Colours are designed in display space and lifted to HDR with `pdUntonemap`;
// lights add HDR on top so they bloom. Coordinates: painting pixels (1920x1080,
// y down), the painted cabin's space.

#define NW_HZ 468.0
#define NW_VX 1180.0
#define NW_F 1150.0
#define NW_CAMH 1.3
#define NW_SPEED 12.5
#define NW_LAMP 30.0

static float nwCurve(float t) { return 0.0007 * sin(t * 0.083) + 0.00035 * sin(t * 0.031 + 1.0); }
static float nwHeading(float t) { return 0.35 * 2.0 * NW_SPEED * (-0.0084337 * cos(t * 0.083) - 0.0112903 * cos(t * 0.031 + 1.0)); }
static float nwCentre(float z, float c) { return 1.65 + c * z * z; }
static float nwLeafNoise(float2 q) { return gnoise(q) * 0.6 + gnoise(q * 2.3 + 7.0) * 0.4; }

// ---------------------------------------------------------------- far away
// The sky, the moon, the misty mountains and the lake are a painted panorama
// (Resources/NightDrive/drive-sky.jpg, made in Canva), mapped onto the view by
// direction: horizon at v = 0.58, so the mountains stand at the right height
// above the painted road's vanishing point. A little mist drifts across it.
static float3 nwPano(float bx, float y, float t, texture2d<float> sky) {
    float2 uv = float2(0.5 + bx * 0.55, 0.58 - y * 1.6);
    float3 c = sky.sample(artSampler, uv).rgb;
    float band = exp(-pow((y - 0.025) / 0.03, 2.0));
    float mist = smoothstep(0.5, 0.85, fbm3(float2(bx * 3.0 - t * 0.012, y * 40.0)));
    c = mix(c, float3(0.55, 0.62, 0.82), band * mist * 0.12);
    // a few stars twinkle
    float lum = dot(c, float3(0.3, 0.5, 0.2));
    float awayFromMoon = smoothstep(0.05, 0.08, length((uv - float2(0.869, 0.131)) * float2(2.0, 1.0)));
    c *= 1.0 + smoothstep(0.55, 0.85, lum) * step(0.08, y) * awayFromMoon * 0.3 * sin(t * 2.3 + hash2(floor(uv * 900.0)) * 40.0);
    return c;
}

// Light from the street lamps reaching a point (s along the road, u across, h up).
static float nwLampLight(float s, float u, float h) {
    float n0 = floor(s / NW_LAMP + 0.5);
    float l = 0.0;
    for (int k = -1; k <= 1; k++) {
        float ds = s - (n0 + float(k)) * NW_LAMP;
        float du = u + 3.4;
        float dh = h - 7.4;
        l += 24.0 / (ds * ds + du * du + dh * dh + 9.0);
    }
    return l;
}

// ---------------------------------------------------------------- the scene
static float3 nwWorld(float2 ip, float t, float bass, float pxs,
                      texture2d<float> sky, texture2d<float> trees, texture2d<float> treesA) {
    float x = (ip.x - NW_VX) / NW_F;
    float y = (NW_HZ - ip.y) / NW_F;
    float dist = t * NW_SPEED;
    float c = nwCurve(t);
    float bx = x + nwHeading(t);
    float3 warm = float3(1.0, 0.66, 0.32);
    float3 haze = float3(0.15, 0.21, 0.38);
    float3 emit = float3(0.0);
    float zHit = 100000.0;
    float3 col = nwPano(bx, y, t, sky);
    float roadZ = -1.0;          // depth of the road surface at this pixel (for reflections)

    // ---- the ground: road, verges, the hillside on the left, the lake ----
    float zg = y < -0.0002 ? NW_CAMH / (-y) : 100000.0;
    float u = y < -0.0002 ? x * zg - nwCentre(zg, c) : -100.0;
    {
        // the hillside rising from the left verge: h = k (-u - 5.6), up to 14 m
        float k = 0.62;
        float a = k * c;
        float b = -(k * x + y);
        float cc = k * (nwCentre(0.0, 0.0) - 5.6) - NW_CAMH;
        float disc = b * b - 4.0 * a * cc;
        if (disc > 0.0 && b > 0.0) {
            float zs = 2.0 * cc / (-b - sqrt(disc));
            float us = x * zs - nwCentre(zs, c);
            if (zs > 0.3 && zs < zg && us < -5.6 && (-us - 5.6) * k < 14.0) { zg = zs; u = us; }
        }
    }
    if (zg < 99999.0) {
        float s = zg + dist;
        float h = max(0.0, (-u - 5.6) * 0.62);
        float mpp = zg * pxs;
        float spp = zg * zg * pxs / NW_CAMH;
        float fog = 1.0 - exp(-zg / 230.0);
        float lampL = nwLampLight(s, u, h);
        zHit = zg;
        if (u > 6.2) {
            // the lake: the painted water and its reflections, rippling gently
            float rip = fbm3(float2(u * 0.2 + t * 0.03, s * 0.08 + t * 0.15)) - 0.5;
            col = nwPano(bx + rip * 0.004, y + rip * 0.0015, t, sky);
        } else if (u < -5.6) {
            // grass, shrubs and rocks on the slope, gold under the lamps
            float2 g = float2(s * 0.6, h * 1.6);
            float bush = fbm3(g * 0.45);
            float clump = nwLeafNoise(g * 1.3);
            float3 grass = mix(float3(0.025, 0.055, 0.045), float3(0.05, 0.105, 0.075), smoothstep(0.4, 0.6, clump));
            float shrub = smoothstep(0.55, 0.6, bush);
            grass = mix(grass, mix(float3(0.02, 0.05, 0.05), float3(0.07, 0.14, 0.11), smoothstep(0.45, 0.65, clump)), shrub);
            float rock = smoothstep(0.7, 0.74, fbm3(g * 0.3 + 11.0)) * step(h, 3.0);
            grass = mix(grass, float3(0.16, 0.15, 0.17) * (0.8 + 0.4 * clump), rock);
            col = mix(grass, float3(0.36, 0.37, 0.15) * (0.7 + 0.5 * clump), smoothstep(0.2, 1.0, lampL) * 0.6);
            col = mix(col, haze, fog);
        } else {
            float au = abs(u);
            float far = smoothstep(25.0, 90.0, zg);
            float grain = mix(fbm3(float2(u * 2.0, s * 0.9)), 0.5, far);
            float3 asphalt = float3(0.10, 0.11, 0.15) * (0.85 + 0.3 * grain);
            asphalt = mix(asphalt, float3(0.22, 0.25, 0.36), 0.35 * exp(y * 25.0));
            float cl = clamp((0.07 - au) / mpp + 0.5, 0.0, 1.0) * min(1.0, 0.14 / mpp);
            float ph = fract(s / 10.0);
            float aw = spp / 10.0 + 0.003;
            float dash = smoothstep(0.0, aw, ph) * (1.0 - smoothstep(0.32, 0.32 + aw, ph));
            float edge = clamp((0.075 - abs(au - 3.4)) / mpp + 0.5, 0.0, 1.0) * min(1.0, 0.15 / mpp);
            float mark = max(cl * dash, edge) * (1.0 - 0.5 * far);
            col = mix(asphalt, float3(0.62, 0.62, 0.6), mark);
            if (au > 3.55) {
                float3 verge = mix(float3(0.10, 0.10, 0.11), float3(0.05, 0.10, 0.07), smoothstep(4.0, 4.8, au));
                col = verge * (0.85 + 0.3 * grain);
            }
            // our headlights and the lamps on the road
            float beam = smoothstep(8.0, 14.0, zg) * exp(-zg / 30.0) * exp(-pow((u + 1.6) / (1.5 + 0.08 * zg), 2.0));
            col *= 1.0 + float3(1.0, 0.96, 0.88) * beam * 1.4 + warm * lampL * 1.3;
            roadZ = au < 4.2 ? zg : -1.0;
            col = mix(col, haze, fog);
        }
    }

    // ---- trees: on the hillside (two rows) and along the lake bank ----
    for (int row = 0; row < 3; row++) {
        float spacing = row == 0 ? 11.0 : (row == 1 ? 7.0 : 16.0);
        float rowU = row == 0 ? -8.2 : (row == 1 ? -15.0 : 7.2);
        int count = row == 1 ? 18 : 13;
        float n0 = floor(dist / spacing);
        for (int i = count - 1; i >= 0; i--) {
            float id = n0 + float(i);
            float hh = hash1(id * 1.37 + float(row) * 11.0);
            float present = row == 2 ? step(0.45, fbm3(float2(id * 0.35, 5.0))) * step(0.25, hh) : step(0.1, hh);
            if (present < 0.5) continue;
            float st = (id + 0.2 + 0.6 * fract(hh * 17.0)) * spacing;
            float zt = st - dist;
            if (zt < 1.0) continue;
            float ut = rowU + (fract(hh * 23.0) - 0.5) * (row == 1 ? 4.0 : 1.6);
            float hb = ut < -5.6 ? (-ut - 5.6) * 0.62 : 0.0;
            float Hm = (row == 2 ? 8.0 : 10.0) + 3.5 * fract(hh * 31.0);
            float Wm = Hm * 0.78;
            float X = (ut + nwCentre(zt, c)) / zt;
            float2 q = float2((x - X) * zt, y * zt + NW_CAMH - hb);
            if (abs(q.x) > Wm * 0.5 || q.y < 0.0 || q.y > Hm) continue;
            if (zt > zHit) continue;
            // one of two painted trees, turned so its lamplit side faces the road
            float k = step(0.5, fract(hh * 7.0));
            bool flip = (k < 0.5) == (ut < 0.0);
            float tu = q.x / Wm + 0.5;
            if (flip) tu = 1.0 - tu;
            float2 tuv = float2((k + clamp(tu, 0.002, 0.998)) * 0.5, clamp(1.0 - q.y / Hm, 0.0, 1.0));
            float cov = treesA.sample(spriteSampler, tuv).r;
            if (cov < 0.01) continue;
            float3 tc = trees.sample(spriteSampler, tuv).rgb;
            float lamp = nwLampLight(st, ut, hb + Hm * 0.6);
            tc *= 0.5 + 0.6 * clamp(lamp, 0.0, 1.2);
            tc = mix(tc, haze * 0.85, 1.0 - exp(-zt / (row == 1 ? 150.0 : 200.0)));
            col = mix(col, tc, cov);
            if (cov > 0.5) { zHit = zt; roadZ = -1.0; }
        }
    }

    // ---- white posts on both verges ----
    for (int side = 0; side < 2; side++) {
        float spacing = side == 0 ? 9.0 : 6.0;
        float up = side == 0 ? -4.5 : 4.6;
        float n0 = floor(dist / spacing);
        for (int i = 17; i >= 0; i--) {
            float sp = (n0 + float(i)) * spacing + (side == 0 ? 0.0 : 2.0);
            float zp = sp - dist;
            if (zp < 1.5 || zp > zHit) continue;
            float X = (up + nwCentre(zp, c)) / zp;
            float2 q = float2((x - X) * zp, y * zp + NW_CAMH);
            if (abs(q.x) > 0.4 || q.y > 0.9 || q.y < -0.05) continue;
            float post = sdBox(q - float2(0.0, 0.34), float2(0.11, 0.34), 0.05);
            float cov = 1.0 - smoothstep(-pxs * zp * 0.5, pxs * zp * 0.5, post);
            if (cov < 0.01) continue;
            float lamp = nwLampLight(sp, up, 0.5);
            float3 pc = float3(0.62, 0.64, 0.68) * (0.75 + 0.25 * smoothstep(0.1, -0.1, q.x * (side == 0 ? 1.0 : -1.0)));
            pc = pc * (0.55 + 0.45 * smoothstep(0.0, 0.6, q.y)) + warm * lamp * 0.45;
            pc += float3(0.9, 0.9, 0.85) * exp(-zp / 25.0) * smoothstep(6.0, 12.0, zp) * 0.35;
            pc = mix(pc, haze, 1.0 - exp(-zp / 230.0));
            col = mix(col, pc, cov);
            if (cov > 0.5) { zHit = zp; roadZ = -1.0; }
        }
    }

    // ---- street lamps on the left verge ----
    float l0 = floor(dist / NW_LAMP);
    float glow = 0.0;
    for (int i = 0; i < 8; i++) {
        float zl = (l0 + 8.0 - float(i)) * NW_LAMP - dist;
        if (zl < 0.8) continue;
        float cen = nwCentre(zl, c);
        float X = (-5.0 + cen) / zl;
        float fog = exp(-zl / 230.0);
        float2 q = float2((x - X) * zl, y * zl + NW_CAMH);     // metres on the lamp's plane
        if (zl < zHit) {
            float pw = 0.07;
            float pole = max(abs(q.x) - pw * (1.0 - q.y * 0.02), max(q.y - 7.3, -q.y));
            // the arm curving out over the road
            float2 ac = float2(0.9, 7.0);
            float arm = abs(length((q - ac) * float2(1.0, 1.6)) - 0.9) - 0.04;
            arm = max(arm, max(-q.x, max(ac.y - q.y, q.x - 1.75)));
            float head = sdBox(q - float2(1.85, 7.82), float2(0.28, 0.07), 0.05);
            float frame = min(min(pole, arm), head);
            float cov = 1.0 - smoothstep(-pxs * zl * 0.6, pxs * zl * 0.6, frame);
            float3 metal = float3(0.30, 0.31, 0.35) * (0.6 + 0.4 * smoothstep(0.05, -0.05, q.x)) + warm * 0.12;
            col = mix(col, mix(metal, haze, 1.0 - fog), cov);
        }
        float2 dh = q - float2(1.85, 7.72);
        float d = length(dh * float2(1.0, 1.4));
        float bright = 1.0 + 0.2 * bass;
        emit += float3(4.2, 3.2, 1.9) * (1.0 - smoothstep(0.16, 0.3, length(dh * float2(1.0, 3.0)))) * fog * bright;
        emit += warm * (exp(-d / 0.7) * 0.5 + exp(-d / 3.5) * 0.09) * fog * bright;
        glow += exp(-d / 2.5) * fog;
        // a soft reflection on the damp road
        if (roadZ > 0.0) {
            float yr = -(NW_CAMH + 7.7) / zl;
            float rx = (x - (X + 1.85 / zl)) * zl;
            float ry = (y - yr) * zl;
            emit += warm * exp(-rx * rx / 0.25) * (ry < 0.0 ? exp(ry / (1.5 + zl * 0.1)) : exp(-ry / 0.6)) * fog * 0.22 * bright;
        }
    }

    // ---- a few raindrops falling through the lamplight ----
    float2 fg = float2(ip.x * 0.08, ip.y * 0.011 - t * 7.0);
    float fh = hash1(floor(fg.x) * 1.7);
    float fall = step(0.55, fh) * (1.0 - smoothstep(0.06, 0.2, abs(fract(fg.x) - 0.5))) * smoothstep(0.8, 1.0, fract(fg.y + fh * 7.0));
    emit += warm * fall * min(glow, 1.2) * 0.25;

    return pdUntonemap(clamp(col, 0.0, 0.97)) + emit;
}

// Warm light thrown into the cabin by the street lamps going by (0...1+).
static float nwLampPass(float t) {
    float dist = t * NW_SPEED;
    float n0 = floor(dist / NW_LAMP);
    float p = 0.0;
    for (int k = 0; k < 2; k++) {
        float zl = (n0 + float(k)) * NW_LAMP - dist;
        p += exp(-pow(zl - 1.0, 2.0) * 0.035);
    }
    return p;
}


// ---- the instrument cluster: a 10.25-inch digital display behind the wheel,
// a tachometer on the left and the speedometer on the right, with glowing
// sweep arcs, ticks and needles that follow the drive (45 km/h, give or take).
static float pdNwSpeed(float t) { return 45.0 + 1.5 * sin(t * 0.05) + 0.8 * sin(t * 0.23); }

static float3 pdDial(float2 ip, float2 c, float R, float v, float majors, float redFrom, float3 col) {
    float2 d = ip - c;
    float r = length(d);
    if (r > R + 6.0) return col;
    float ang = atan2(-d.y, d.x);                         // y up
    // position along the 270-degree sweep (0 at bottom left, 1 at bottom right)
    float a = 3.92699 - ang;                              // 225 degrees
    a = a - 6.2831853 * floor(a / 6.2831853);
    float f = a / 4.712389;
    float inSweep = step(f, 1.0);
    // face
    col = mix(col, float3(0.012, 0.02, 0.04) + float3(0.02, 0.05, 0.08) * (1.0 - r / R), 1.0 - smoothstep(R - 1.0, R + 0.5, r));
    // outer ring
    col += float3(0.25, 0.45, 0.6) * exp(-pow(r - R, 2.0) / 0.8) * 0.5;
    // ticks
    float n = majors * 5.0;
    float tf = f * n;
    float tick = abs(fract(tf + 0.5) - 0.5) * (4.712389 * r / n);  // distance to nearest tick, px
    bool major = abs(fract(tf / 5.0 + 0.1) - 0.1) < 0.02;
    float tl = major ? 9.0 : 4.5;
    float tw = major ? 1.1 : 0.6;
    float tm = (1.0 - smoothstep(tw - 0.6, tw + 0.6, tick)) * step(R - 3.0 - tl, r) * step(r, R - 3.0) * inSweep;
    float3 tickCol = f > redFrom ? float3(1.0, 0.3, 0.25) : float3(0.75, 0.85, 0.95);
    col = mix(col, tickCol, tm * (major ? 0.95 : 0.6));
    // the glowing sweep arc up to the value
    float band = exp(-pow(r - (R - 1.5), 2.0) / 2.5) * step(f, v) * inSweep;
    float3 arcCol = mix(float3(0.1, 0.6, 1.0), float3(0.55, 0.95, 1.0), f);
    col += arcCol * band * 1.4;
    col += arcCol * exp(-abs(r - (R - 1.5)) / 6.0) * step(f, v) * inSweep * 0.12;
    // needle
    float na = 3.92699 - v * 4.712389;
    float2 nd = float2(cos(na), -sin(na));
    float along = dot(d, nd);
    float across = abs(d.x * nd.y - d.y * nd.x);
    float needle = (1.0 - smoothstep(0.6, 1.6, across - (1.0 - along / R) * 0.8)) * step(-R * 0.12, along) * step(along, R - 6.0);
    col = mix(col, float3(1.0, 0.42, 0.22) * 1.6, needle);
    col += float3(1.0, 0.4, 0.2) * exp(-across / 2.5) * step(0.0, along) * step(along, R - 6.0) * 0.15;
    // hub
    float hub = 1.0 - smoothstep(5.0, 6.2, r);
    col = mix(col, float3(0.05, 0.06, 0.08) + float3(0.25, 0.3, 0.35) * exp(-pow(r - 5.0, 2.0)), hub);
    return col;
}

// The cluster's picture, centred between two dials (the screen mask shapes it).
static float3 pdCluster(float2 ip, float t, float bass) {
    float2 c = float2(1475.0, 814.0);
    float3 bg = mix(float3(0.006, 0.01, 0.022), float3(0.014, 0.024, 0.048), smoothstep(905.0, 727.0, ip.y));
    bg += float3(0.0, 0.04, 0.07) * exp(-length(ip - (c - float2(130.0, 0.0))) / 62.0);
    bg += float3(0.0, 0.04, 0.07) * exp(-length(ip - (c + float2(130.0, 0.0))) / 62.0);
    bg += float3(0.1, 0.35, 0.5) * exp(-abs(ip.y - 738.0) / 0.8) * step(abs(ip.x - c.x), 110.0) * 0.4;
    float speed = pdNwSpeed(t);
    float rpm = 1450.0 + speed * 9.0 + 220.0 * bass + 60.0 * sin(t * 1.7);
    bg = pdDial(ip, c - float2(130.0, 0.0), 64.0, rpm / 8000.0, 8.0, 0.75, bg);
    bg = pdDial(ip, c + float2(130.0, 0.0), 64.0, speed / 220.0, 11.0, 2.0, bg);
    return bg;
}

// The infotainment: a soft backdrop in the artwork's colours and the song's
// spectrum as LED bars (the title is drawn natively above them).
static float3 pdInfotainment(float2 ip, constant Uniforms &u, texture2d<float> specTex) {
    float2 sMin = float2(626.0, 735.0), sMax = float2(1140.0, 896.0);
    float2 q = (ip - (sMin + sMax) * 0.5) / ((sMax - sMin) * 0.5);
    q.y = -q.y;
    float3 bg = mix(float3(0.02, 0.03, 0.08), float3(0.06, 0.05, 0.12), q.y * 0.5 + 0.5);
    bg += u.p1.rgb * 0.06 * (1.0 - length(q * float2(0.6, 1.0)));
    float bars = 32.0;
    float bx = (q.x * 0.5 + 0.5) * bars;
    float v = spec(specTex, floor(bx) / bars * 0.9);
    float barTop = -0.9 + v * 0.75;
    float colBar = step(0.2, fract(bx)) * step(fract(bx), 0.8) * step(-0.9, q.y) * step(abs(q.x), 1.0);
    float3 barCol = mix(float3(0.3, 0.9, 1.0), u.p0.rgb, smoothstep(-0.9, -0.2, q.y));
    bg += barCol * colBar * step(q.y, barTop) * 0.9 + barCol * colBar * exp(-max(q.y - barTop, 0.0) * 25.0) * 0.1;
    return bg;
}

static float4 pdScene(float2 fc, constant Uniforms &u, texture2d<float> specTex,
                      texture2d<float> cabin, texture2d<float> masks2,
                      texture2d<float> sky, texture2d<float> trees, texture2d<float> treesA) {
    float2 sz = float2(PD_W, PD_H);
    float s = max(u.res.x / PD_W, u.res.y / PD_H);
    float2 o = (u.res - sz * s) * 0.5;
    float2 ip = float2(fc.x - o.x, (u.res.y - fc.y) - o.y) / s;     // painting pixels, y down
    float2 p = float2(ip.x - PD_W * 0.5, PD_H * 0.5 - ip.y) / PD_H;  // height units, y up
    float t = u.time;
    float px = 1.0 / (PD_H * s);
    float pxs = 1.0 / (NW_F * s);
    float4 mk = masks2.sample(linearSampler, ip / sz);
    float glass = 1.0 - mk.r, mirror = mk.g, screen = mk.b;
    float3 view = float3(0.0);
    if (glass > 0.002) {
        // rain on the glass and the wipers (pivots at the foot of the windshield)
        float blade;
        float2 wp = (p - float2(0.06, -0.12)) * 0.62;
        float since = drvWipe(wp, t, blade);
        float3 r = driveRain(wp, t, since);
        float2 refr = float2(r.x, -r.y) * PD_H;
        view = nwWorld(ip + refr * 2.5, t, u.bass, pxs, sky, trees, treesA);
        if (r.z > 0.01) {
            float3 sharp = nwWorld(ip - refr * 5.0, t, u.bass, pxs, sky, trees, treesA);
            view = mix(view, sharp * 1.1 + 0.015, r.z * 0.7);
        }
        view *= 0.94 + 0.06 * (1.0 - r.z);
        float sweeping = step(t - 7.0 * floor(t / 7.0), 1.32);
        view = mix(view, float3(0.012, 0.012, 0.018), clamp(0.5 - blade / (px * 0.62), 0.0, 1.0) * 0.95 * sweeping);
    }
    // the painted cabin, lit by the lamps going by
    float3 cab = pdUntonemap(cabin.sample(linearSampler, ip / sz).rgb);
    float pass = nwLampPass(t) * (1.0 + 0.3 * u.bass);
    float fromLeft = smoothstep(0.8, -0.7, p.x) * smoothstep(-0.5, 0.0, p.y);
    float3 lit = cab * (1.0 + float3(1.0, 0.66, 0.36) * pass * 0.4 * fromLeft);
    // the rear-view mirror: the road behind, receding (a mirror keeps the hillside on the left)
    if (mirror > 0.01) {
        float2 mc = float2(947.0, 96.0), mh = float2(220.0, 54.0);
        float2 mq = (ip - mc) / mh;                                   // -1...1 across the glass
        float2 rip = float2(NW_VX + mq.x * 520.0, NW_HZ - 40.0 + mq.y * 150.0);
        float3 rear = nwWorld(rip, -t - 30.0, u.bass * 0.5, pxs * 2.4, sky, trees, treesA);
        rear = rear * float3(0.62, 0.66, 0.74) + 0.006;
        rear *= 1.0 - 0.35 * pow(length(mq * float2(0.9, 1.0)), 3.0);
        rear += float3(0.04, 0.05, 0.07) * smoothstep(0.2, -0.9, mq.y + mq.x * 0.3) * 0.5;   // a sheen across the glass
        lit = mix(lit, rear, mirror);
    }
    // the dual display: infotainment on the left, the cluster behind the wheel
    if (screen > 0.01) {
        float3 disp = ip.x < 1150.0 ? pdInfotainment(ip, u, specTex) : (ip.x < 1236.0 ? float3(0.008, 0.012, 0.026) : pdCluster(ip, t, u.bass));
        disp *= 1.0 + 0.06 * u.beat;
        lit = mix(lit, disp, screen);
    }
    float3 col = mix(lit, view, glass);
    float outside = min(step(ip.x, 0.0) + step(PD_W, ip.x) + step(ip.y, 0.0) + step(PD_H, ip.y), 1.0);
    col = mix(col, float3(0.012, 0.013, 0.02), outside);
    return float4(col, 1.0);
}

fragment float4 driveFragment(QuadOut in [[stage_in]],
                              constant Uniforms &u [[buffer(0)]],
                              texture2d<float> specTex [[texture(0)]],
                              texture2d<float> cabin [[texture(3)]],
                              texture2d<float> masks2 [[texture(4)]],
                              texture2d<float> sky [[texture(5)]],
                              texture2d<float> trees [[texture(8)]],
                              texture2d<float> treesA [[texture(9)]]) {
    float2 fc = fragCoord(in.position, u);
    if (u.pad1 > 0.5) return pdScene(fc, u, specTex, cabin, masks2, sky, trees, treesA);
    return lofiScene(fc, u, specTex);
}

"""#
}
