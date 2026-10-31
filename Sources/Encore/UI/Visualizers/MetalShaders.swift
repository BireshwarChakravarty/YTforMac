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
    float ca = 0.0012 + u.beat * 0.0018;
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

// ================================================================ Flow
// MilkDrop-style: a glowing spectrum ring is drawn each frame; the feedback
// pass zooms, swirls and fades it into rivers of light.

fragment float4 flowFragment(QuadOut in [[stage_in]],
                             constant Uniforms &u [[buffer(0)]],
                             texture2d<float> specTex [[texture(0)]]) {
    float2 uv = (fragCoord(in.position, u) - 0.5 * u.res) / u.res.y;
    float r = length(uv), a = atan2(uv.y, uv.x);
    float seg = abs(fract(a / (2.0 * M_PI_F) + 0.25) * 2.0 - 1.0);
    float s = spec(specTex, seg * 0.85);
    float ringR = 0.16 + 0.10 * s + 0.03 * u.beat;
    float d = abs(r - ringR);
    float line = exp(-d * d / 0.00002) * (0.6 + 1.6 * s);
    float3 col = pal(u, seg * 0.6 + u.phase * 0.05) * line * 1.3;
    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        float2 sp = 0.12 * float2(cos(u.time * (0.7 + fi * 0.13) + fi * 2.0), sin(u.time * (0.9 + fi * 0.11) + fi));
        col += pal(u, fi / 6.0) * exp(-dot(uv - sp, uv - sp) / 0.00006) * (0.4 + u.treble);
    }
    return float4(col, 1.0);
}

// ================================================================ Halo
// The artwork in a disc, ringed by a radial spectrum of light with soft trails.

fragment float4 haloFragment(QuadOut in [[stage_in]],
                             constant Uniforms &u [[buffer(0)]],
                             texture2d<float> specTex [[texture(0)]],
                             texture2d<float> artTex [[texture(2)]]) {
    float2 uv = (fragCoord(in.position, u) - 0.5 * u.res) / u.res.y - float2(0.0, 0.06);
    float r = length(uv), a = atan2(uv.y, uv.x);
    float R = 0.2 * (1.0 + 0.04 * u.beat);
    float3 col = float3(0.0);
    float n = 96.0;
    float fa = fract(a / (2.0 * M_PI_F) + 0.25);
    float cell = floor(fa * n);
    float centerA = (cell + 0.5) / n;
    float seg = abs(centerA * 2.0 - 1.0);
    float s = spec(specTex, seg * 0.85);
    float len = 0.015 + s * 0.20;
    float aDist = abs(fa - centerA) * 2.0 * M_PI_F * r;
    float px = 1.0 / u.res.y;
    float inBar = (1.0 - smoothstep(0.0015, 0.004 + px, aDist)) * smoothstep(R + 0.012, R + 0.02, r) * (1.0 - smoothstep(R + 0.02 + len, R + 0.024 + len, r));
    col += pal(u, seg * 0.6 + u.phase * 0.03) * inBar * (0.8 + 2.0 * s);
    col += pal(u, 0.1) * exp(-abs(r - R - 0.008) * 160.0) * (0.6 + 1.2 * u.level);
    if (r < R) {
        float2 auv = float2(uv.x, -uv.y) / (2.0 * R) + 0.5;
        float3 art = artTex.sample(artSampler, auv, level(0)).rgb;
        float edge = (1.0 - smoothstep(R - 0.004, R, r));
        col = mix(col, art * (0.9 + 0.2 * u.beat), edge);
    }
    return float4(col, 1.0);
}

// ================================================================ Orb
// A glass sphere rippling with the spectrum; bloom makes the rim sing.

static float mapOrb(float3 p, constant Uniforms &u, texture2d<float> specTex, float R) {
    p.xz = rot(u.time * 0.1) * p.xz;
    p.yz = rot(0.3) * p.yz;
    float ang = atan2(p.z, p.x) / (2.0 * M_PI_F) + 0.5;
    float s = spec(specTex, abs(ang * 2.0 - 1.0) * 0.8);
    float d = length(p) - R;
    float w = sin(p.x * 3.1 + u.time * 0.5) * sin(p.y * 2.7 - u.time * 0.4) * sin(p.z * 3.3 + u.time * 0.45);
    d -= w * (0.018 + 0.03 * u.level) + s * 0.05 * (0.5 + 0.5 * sin(p.y * 7.0 + u.time * 0.7));
    return d * 0.9;
}

fragment float4 orbFragment(QuadOut in [[stage_in]],
                            constant Uniforms &u [[buffer(0)]],
                            texture2d<float> specTex [[texture(0)]]) {
    float2 uv = (fragCoord(in.position, u) - 0.5 * u.res) / u.res.y - float2(0.0, 0.08);
    float R = 0.5 + u.bass * 0.04 + u.beat * 0.03;
    float3 ro = float3(0.0, 0.0, 3.0), rd = normalize(float3(uv, -1.7));
    float3 bg = u.shadow.rgb * 0.6;
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float2 g = (uv + float2(u.time * 0.008 * (fi + 1.0), u.time * 0.005)) * (12.0 + fi * 8.0);
        float2 id = floor(g); float2 f = fract(g) - 0.5;
        float h = hash2(id + fi * 7.0);
        float2 o = float2(hash2(id + 1.3), hash2(id + 2.7)) - 0.5;
        bg += pal(u, h) * (1.0 - smoothstep(0.0, 0.05, length(f - o * 0.7))) * step(0.86, h) * (0.4 + 0.6 * u.treble);
    }
    float t = 0.0, minD = 10.0;
    bool hit = false;
    for (int i = 0; i < 64; i++) {
        float d = mapOrb(ro + rd * t, u, specTex, R);
        minD = min(minD, d);
        if (d < 0.001) { hit = true; break; }
        t += d;
        if (t > 6.0) break;
    }
    float3 col = bg + pal(u, 0.1 + u.phase * 0.02) * exp(-max(minD, 0.0) * 8.0) * (0.35 + 0.8 * u.level);
    if (hit) {
        float3 p = ro + rd * t;
        float2 e = float2(0.002, 0.0);
        float3 n = normalize(float3(mapOrb(p + e.xyy, u, specTex, R) - mapOrb(p - e.xyy, u, specTex, R),
                                    mapOrb(p + e.yxy, u, specTex, R) - mapOrb(p - e.yxy, u, specTex, R),
                                    mapOrb(p + e.yyx, u, specTex, R) - mapOrb(p - e.yyx, u, specTex, R)));
        float facing = max(dot(n, -rd), 0.0), fres = pow(1.0 - facing, 3.0);
        float3 L = normalize(float3(-0.5, 0.65, 0.6));
        float3 rr = refract(rd, n, 0.78);
        float sw = gnoise(rr.xy * 2.4 + float2(u.time * 0.05, -u.time * 0.03));
        col = bg * 0.5 + pal(u, 0.55 + sw * 0.4) * 0.22 * (0.6 + u.level) + pal(u, 0.12) * pow(facing, 7.0) * (0.3 + 0.6 * u.level);
        col += fres * pal(u, 0.25 + n.y * 0.15) * 2.4;
        col += pal(u, fres * 0.7 + n.x * 0.2) * fres * 0.8;
        col += pow(max(dot(reflect(rd, n), L), 0.0), 60.0) * 2.0;
    }
    return float4(col, 1.0);
}

// ================================================================ Tide
// A sea of light points; the newest sound arrives in the foreground.

fragment float4 tideBackground(QuadOut in [[stage_in]],
                               constant Uniforms &u [[buffer(0)]],
                               texture2d<float> specTex [[texture(0)]]) {
    float2 uv = (fragCoord(in.position, u) - 0.5 * u.res) / u.res.y;
    float3 c = mix(u.shadow.rgb * 0.5, u.shadow.rgb * 0.9 + u.p2.rgb * 0.08, smoothstep(-0.5, 0.45, uv.y));
    c += u.p1.rgb * 0.18 * exp(-abs(uv.y - 0.2) * 7.0) * (0.5 + u.level);
    return float4(c, 1.0);
}

vertex PointOut tideVertex(uint vid [[vertex_id]],
                           constant Uniforms &u [[buffer(0)]],
                           texture2d<float> specTex [[texture(0)]],
                           texture2d<float> hist [[texture(1)]]) {
    float i = float(vid);
    float cx = i - 220.0 * floor(i / 220.0), cz = floor(i / 220.0);
    float uu = cx / 219.0, w = (cz + u.scroll) / 110.0;
    float fx = abs(uu * 2.0 - 1.0);
    float v = hist.sample(linearSampler, float2(fx * 0.8 + 0.03, clamp(w, 0.0, 1.0)), level(0)).r;
    float x = (uu - 0.5) * 40.0, z = w * 70.0 + 2.0;
    float y = sin(x * 0.22 + u.time * 0.5 + z * 0.09) * 0.55 + sin(z * 0.18 - u.time * 0.35 + x * 0.05) * 0.6;
    y += pow(v, 1.4) * 6.5 * (1.0 - fx * 0.55);
    float3 pw = float3(x, y, z) - float3(0.0, 7.0, -3.0);
    float pitch = 0.36, cp = cos(pitch), sp = sin(pitch);
    float3 pc = float3(pw.x, pw.y * cp + pw.z * sp, -pw.y * sp + pw.z * cp);
    PointOut o;
    o.position = float4(pc.x * 1.35 / (u.res.x / u.res.y), pc.y * 1.35, pc.z * 0.01, pc.z);
    float depth = clamp(1.0 - w, 0.0, 1.0);
    o.pointSize = max(1.0, (1.2 + v * 2.2) * (0.55 + depth * 1.25)) * u.dpr;
    float3 col = mix(pal(u, 0.6 + uu * 0.25), pal(u, 0.05 + v * 0.6), smoothstep(0.1, 0.7, v));
    o.color = col * (0.25 + v * v * 3.0 + u.beat * 0.3) * depth * depth;
    return o;
}

// ================================================================ Aurora
// Real northern lights: draped curtains marched through altitude layers.
// Oxygen green, a pink lower fringe, red/violet tops; stars, mountains, a lake.

static float auroraCurtain(float2 p, float t) {
    float wob = fbm3(float2(p.x * 0.12 + t * 0.03, 1.7)) * 9.0 + fbm3(float2(p.x * 0.45 - t * 0.06, 4.2)) * 2.2;
    float d1 = abs(p.y - (4.2 + wob * 0.7));
    float wob2 = fbm3(float2(p.x * 0.1 - t * 0.02, 8.3)) * 10.0;
    float d2 = abs(p.y - (8.0 + wob2 * 0.8));
    float sheet = exp(-d1 * 1.6) + 0.6 * exp(-d2 * 1.2);
    float rays = 0.45 + 0.55 * pow(gnoise(float2(p.x * 4.0 + wob * 0.6, t * 0.25)), 1.5);
    float folds = 0.6 + 0.4 * sin(p.x * 0.8 + wob * 1.5 + t * 0.2);
    return sheet * rays * folds;
}
static float3 auroraColor(float h) {
    float3 pink = float3(1.0, 0.25, 0.55), green = float3(0.15, 1.0, 0.45), red = float3(0.85, 0.12, 0.35), violet = float3(0.45, 0.2, 0.9);
    float3 c = mix(pink, green, smoothstep(0.0, 0.08, h));
    return mix(c, mix(red, violet, 0.4), smoothstep(0.45, 1.0, h));
}
static float3 auroraSky(float3 rd, float t, float jitter, constant Uniforms &u, texture2d<float> specTex) {
    float3 c = mix(float3(0.010, 0.020, 0.045), float3(0.002, 0.004, 0.012), smoothstep(0.0, 0.6, rd.y));
    float2 sp = rd.xz / max(rd.y + 0.15, 0.05) * 220.0;
    float2 id = floor(sp); float2 f = fract(sp) - 0.5;
    float h = hash2(id);
    float star = step(0.985, h) * (1.0 - smoothstep(0.0, 0.08 + 0.06 * fract(h * 37.0), length(f))) * (0.6 + 0.4 * sin(u.time * (1.0 + h * 3.0) + h * 50.0));
    c += mix(float3(0.7, 0.8, 1.0), float3(1.0, 0.9, 0.75), fract(h * 13.0)) * star * 1.4;
    float3 acc = float3(0.0);
    float energy = 0.55 + 0.9 * u.level + 0.6 * u.beat;
    for (int i = 0; i < 56; i++) {
        float fi = float(i) + jitter;
        float alt = 0.9 + fi * 0.06;
        float tt = alt / max(rd.y, 0.015);
        float2 p = rd.xz * tt * 0.9 + float2(0.0, 2.0);
        float d = auroraCurtain(p, t);
        float s = spec(specTex, fract(p.x * 0.05 + 0.5));
        acc += auroraColor(fi / 56.0) * d * exp(-fi * 0.05) * (0.6 + 0.8 * s);
    }
    c += acc * 0.34 * energy * smoothstep(0.0, 0.08, rd.y);
    return c;
}

fragment float4 auroraFragment(QuadOut in [[stage_in]],
                               constant Uniforms &u [[buffer(0)]],
                               texture2d<float> specTex [[texture(0)]]) {
    float2 uv = (fragCoord(in.position, u) - 0.5 * u.res) / u.res.y;
    float t = u.time * (0.6 + 0.4 * u.mid) + u.phase * 0.2;
    float jitter = hash2(floor(in.position.xy)) * 0.5;
    float3 rd = normalize(float3(uv.x, uv.y + 0.36, 1.0));
    float3 col;
    if (rd.y > 0.0) {
        col = auroraSky(rd, t, jitter, u, specTex);
    } else {
        float3 rr = float3(rd.x, -rd.y, rd.z);
        rr.x += 0.003 * sin(uv.y * 160.0 + u.time * 1.5) * (1.0 + u.bass * 2.0);
        col = auroraSky(rr, t, jitter, u, specTex) * 0.45 * smoothstep(-0.6, 0.0, rd.y) + float3(0.002, 0.004, 0.01);
    }
    float x = uv.x;
    float hy = -0.36;
    float ridge = 0.045 + 0.06 * gnoise(float2(x * 2.2, 0.0)) + 0.025 * gnoise(float2(x * 7.0, 3.0)) + 0.008 * gnoise(float2(x * 25.0, 1.0)) + hy;
    float3 mountain = float3(0.006, 0.01, 0.018);
    float m = (1.0 - smoothstep(ridge - 0.002, ridge + 0.002, uv.y)) * smoothstep(hy - 0.002, hy + 0.002, uv.y);
    col = mix(col, mountain, m);
    float mirrorY = 2.0 * hy - uv.y;
    float mr = (1.0 - smoothstep(ridge - 0.002, ridge + 0.002, mirrorY)) * (1.0 - smoothstep(hy - 0.002, hy + 0.002, uv.y));
    col = mix(col, mountain * 0.7, mr * 0.9);
    return float4(col, 1.0);
}

// ================================================================ Cosmos
// A spiral galaxy (warm core, blue arms, pink star-forming regions) in a deep
// starfield with nebulae.

fragment float4 cosmosBackground(QuadOut in [[stage_in]],
                                 constant Uniforms &u [[buffer(0)]],
                                 texture2d<float> specTex [[texture(0)]]) {
    float2 uv = (fragCoord(in.position, u) - 0.5 * u.res) / u.res.y;
    float2 q = uv + float2(u.time * 0.003, 0.0);
    float n1 = fbm3(q * 1.6 + fbm3(q * 2.3 + 4.0) * 1.2);
    float n2 = fbm3(q * 2.4 - float2(3.0, 1.0) + fbm3(q * 1.7) * 1.5);
    float3 c = float3(0.004, 0.005, 0.012);
    c += float3(0.30, 0.08, 0.35) * pow(smoothstep(0.42, 0.85, n1), 2.0) * 0.8;
    c += float3(0.05, 0.18, 0.40) * pow(smoothstep(0.45, 0.9, n2), 2.0) * 0.8;
    c += float3(0.6, 0.25, 0.15) * pow(smoothstep(0.62, 1.0, n1 * n2 * 1.6), 3.0) * 0.25;
    c *= 0.6 + 0.4 * smoothstep(0.3, 0.6, fbm3(q * 3.0 + 9.0));
    for (int l = 0; l < 3; l++) {
        float fl = float(l);
        float2 g = (uv + float2(u.time * 0.002 * (fl + 1.0), 0.0)) * (90.0 + fl * 110.0);
        float2 id = floor(g); float2 f = fract(g) - 0.5;
        float h = hash2(id + fl * 17.0);
        if (h > 0.96 - fl * 0.01) {
            float2 o = float2(hash2(id + 3.1), hash2(id + 7.7)) - 0.5;
            float d = length(f - o * 0.7);
            float size = (0.03 + 0.09 * pow(fract(h * 91.0), 6.0)) * (1.0 - fl * 0.25);
            float temp = fract(h * 53.0);
            float3 sc = temp < 0.2 ? float3(0.6, 0.75, 1.0) : temp < 0.7 ? float3(1.0, 0.97, 0.92) : temp < 0.9 ? float3(1.0, 0.85, 0.6) : float3(1.0, 0.6, 0.4);
            float tw = 0.75 + 0.25 * sin(u.time * (1.0 + h * 4.0) + h * 80.0) * (0.5 + u.treble);
            c += sc * (exp(-d * d / (size * size * 0.15)) * 2.0 + exp(-d / (size * 1.5)) * 0.15) * tw;
        }
    }
    return float4(c, 1.0);
}

vertex PointOut cosmosVertex(uint vid [[vertex_id]],
                             constant Uniforms &u [[buffer(0)]],
                             texture2d<float> specTex [[texture(0)]]) {
    float id = float(vid);
    float h1 = hash1(id * 1.13), h2 = hash1(id * 7.31 + 1.0), h3 = hash1(id * 3.77 + 2.0), h4 = hash1(id * 0.61 + 5.0), h5 = hash1(id * 2.93 + 9.0);
    float3 p, col;
    float bright;
    float rot = u.time * 0.035 + u.phase * 0.02;
    if (h5 < 0.18) {
        float r = pow(h1, 2.2) * 0.45;
        float th = h2 * 6.2831, ph = acos(2.0 * h3 - 1.0);
        p = float3(sin(ph) * cos(th), cos(ph) * 0.55, sin(ph) * sin(th)) * r;
        col = mix(float3(1.0, 0.86, 0.62), float3(1.0, 0.95, 0.85), h4);
        bright = 0.55 * (1.0 - r * 1.2) + 0.25;
    } else {
        float r = 0.18 + pow(h1, 1.15) * 2.0;
        float arm = floor(h4 * 2.0);
        float spread = (h2 - 0.5) * (0.5 + 0.3 * r) * (h3 < 0.6 ? 0.5 : 2.4);
        float ang = arm * 3.14159 + log(r) * 2.6 + spread - rot / pow(r + 0.2, 0.5) * 0.6;
        p = float3(cos(ang) * r, (h3 - 0.5) * 0.06 * (1.0 + r * 0.3), sin(ang) * r);
        bool hii = fract(h3 * 31.0) < 0.06 && abs(spread) < 0.12;
        col = hii ? float3(1.0, 0.3, 0.55) : mix(float3(0.45, 0.62, 1.0), float3(0.85, 0.9, 1.0), h5 * h5);
        col = mix(float3(1.0, 0.78, 0.5), col, smoothstep(0.25, 0.9, r));
        bright = (hii ? 1.6 : 0.5) * (1.0 - smoothstep(1.4, 2.2, r)) * (abs(spread) < 0.18 ? 1.0 : 0.5);
    }
    float band = clamp(length(p) / 2.2, 0.0, 1.0);
    float e = spec(specTex, band * 0.85);
    bright *= 0.55 + 1.2 * e + 0.6 * u.beat * (1.0 - band);
    float ca = u.time * 0.02;
    float3 ro = float3(sin(ca) * 1.7, 2.0 + 0.15 * sin(u.time * 0.03), cos(ca) * 1.7);
    float3 fw = normalize(-ro), rt = normalize(cross(float3(0, 1, 0), fw)), up = cross(fw, rt);
    float3 q = p - ro;
    float3 v = float3(dot(q, rt), dot(q, up), dot(q, fw));
    PointOut o;
    o.position = float4(v.x * 1.7 / (u.res.x / u.res.y), v.y * 1.7, v.z * 0.05, v.z);
    o.pointSize = clamp(5.0 / max(v.z, 0.1), 1.0, 6.0) * u.dpr;
    o.color = min(col * bright * 0.65 / (u.dpr * u.dpr), 3.0);
    return o;
}

// ================================================================ Ambient
// A vibrant mesh gradient from the artwork's own colours, drifting bokeh, and
// the cover floating in front with a shadow, glow and a gentle tilt.

static float3 vivid(float3 c) { float l = dot(c, float3(0.299, 0.587, 0.114)); c = clamp(mix(float3(l), c, 2.3), 0.0, 1.0); return pow(c, float3(1.35)); }
static float roundBox(float2 p, float2 b, float r) { float2 q = abs(p) - b + r; return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r; }

fragment float4 ambientFragment(QuadOut in [[stage_in]],
                                constant Uniforms &u [[buffer(0)]],
                                texture2d<float> specTex [[texture(0)]],
                                texture2d<float> artTex [[texture(2)]]) {
    float2 uv = fragCoord(in.position, u) / u.res;
    float aspect = u.res.x / u.res.y;
    float2 p = (uv - 0.5) * float2(aspect, 1.0);
    float t = u.time * 0.07 + u.phase * 0.03;
    float lowLod = max(log2(max(float(artTex.get_width()), 1.0)) - 3.0, 0.0);
    float3 cs[5];
    cs[0] = vivid(artTex.sample(artSampler, float2(0.2, 0.25), level(lowLod)).rgb);
    cs[1] = vivid(artTex.sample(artSampler, float2(0.8, 0.3), level(lowLod)).rgb);
    cs[2] = vivid(artTex.sample(artSampler, float2(0.3, 0.8), level(lowLod)).rgb);
    cs[3] = vivid(artTex.sample(artSampler, float2(0.75, 0.75), level(lowLod)).rgb);
    cs[4] = vivid(artTex.sample(artSampler, float2(0.5, 0.5), level(lowLod)).rgb);
    float2 w = float2(fbm3(p * 0.7 + t * 0.6), fbm3(p * 0.7 - t * 0.5 + 5.0)) - 0.5;
    float2 q = p + w * 0.5;
    float3 col = float3(0.0);
    float wsum = 0.0;
    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        float2 c = float2(0.65 * aspect * 0.5 * sin(t * (0.8 + fi * 0.23) + fi * 1.7), 0.45 * cos(t * (0.6 + fi * 0.19) + fi * 2.6));
        float wt = exp(-dot(q - c, q - c) * (3.2 - u.bass * 0.8));
        col += cs[i] * wt; wsum += wt;
    }
    col /= max(wsum, 1e-3);
    col *= 0.42 + 0.4 * smoothstep(-0.7, 0.7, q.y + q.x * 0.3);
    col *= 1.0 - 0.35 * dot(p, p);
    for (int i = 0; i < 14; i++) {
        float fi = float(i);
        float2 bp = float2(hash1(fi * 3.1) - 0.5, hash1(fi * 7.7) - 0.5) * float2(aspect, 1.0);
        bp += 0.08 * float2(sin(t * (0.9 + fi * 0.1) + fi), cos(t * (0.7 + fi * 0.13) + fi * 2.0));
        float r = 0.03 + 0.06 * hash1(fi * 1.7);
        float bd = length(p - bp);
        float disc = (1.0 - smoothstep(r * 0.8, r, bd)) * (0.7 + 0.3 * smoothstep(r * 0.5, r, bd));
        col += cs[i % 5] * disc * (0.12 + 0.25 * u.beat + 0.15 * spec(specTex, hash1(fi * 2.3)));
    }
    col += float3(1.0) * pow(max(0.0, sin((q.x + q.y) * 2.5 - t * 2.0)), 24.0) * 0.06;
    // floating cover
    float2 center = float2(0.0, 0.12);
    float sz = 0.2 * (1.0 + 0.012 * u.beat);
    float2 cp = p - center;
    float tilt = sin(t * 1.3) * 0.06;
    cp.x *= 1.0 + cp.y * tilt * 2.0;
    float d = roundBox(cp, float2(sz), 0.022);
    float shadow = exp(-max(roundBox(cp - float2(0.0, -0.025), float2(sz), 0.03), 0.0) * 22.0) * 0.55;
    col *= 1.0 - shadow;
    col += cs[4] * exp(-max(d, 0.0) * 9.0) * (0.12 + 0.35 * u.bass);
    if (d < 0.0) {
        float2 auv = cp / (2.0 * sz) + 0.5;
        auv.y = 1.0 - auv.y;
        float3 art = artTex.sample(artSampler, auv, level(0)).rgb;
        art += float3(1.0) * pow(max(0.0, 1.0 - length(auv - float2(0.2, 0.15)) * 1.4), 3.0) * 0.12;
        col = mix(col, art, smoothstep(0.0, -0.002, d));
    }
    return float4(col, 1.0);
}

// ================================================================ Waves
// Luminous silk ribbons whose height and thickness follow the spectrum.

fragment float4 wavesFragment(QuadOut in [[stage_in]],
                              constant Uniforms &u [[buffer(0)]],
                              texture2d<float> specTex [[texture(0)]]) {
    float2 uv = (fragCoord(in.position, u) - 0.5 * u.res) / u.res.y - float2(0.0, 0.06);
    float aspect = u.res.x / u.res.y;
    float x = uv.x / (0.5 * aspect);
    float env = pow(max(0.0, 1.0 - x * x), 1.6);
    float s = spec(specTex, abs(x) * 0.8);
    float3 col = float3(0.0);
    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        float k = 2.2 + fi * 0.65;
        float ph = u.time * (0.55 + fi * 0.13) * (0.7 + u.level) + fi * 1.9;
        float amp = (0.06 + 0.32 * s + 0.08 * u.beat) * env * (1.0 - fi * 0.09);
        float y = amp * sin(x * k * M_PI_F * 0.5 + ph) * cos(x * (1.3 + fi * 0.4) - ph * 0.6);
        float d = abs(uv.y - y);
        float width = 0.0016 + 0.004 * s * env;
        float3 c = pal(u, fi / 6.0 + x * 0.12 + u.phase * 0.02);
        col += c * (exp(-d * d / (width * width)) * (0.55 + 1.0 * s) + exp(-d / 0.04) * 0.04 * env);
    }
    col += pal(u, 0.2) * exp(-abs(uv.y) / 0.002) * 0.15 * env;
    return float4(col, 1.0);
}

// ================================================================ Night Drive
// A drive toward a retro sunset: neon road, passing streetlights, synthwave
// grid. The car and the radio are drawn natively on top.

constant float DRIVE_HORIZON = 0.02;
constant float DRIVE_CAMH = 1.15;
constant float DRIVE_FOCAL = 0.9;
static float roadCurve(float z, float travel) { return 2.2 * sin((z + travel) * 0.018) + 1.1 * sin((z + travel) * 0.041 + 1.3); }
static float curveRel(float z, float travel) {
    return roadCurve(z, travel) - roadCurve(0.0, travel) - (roadCurve(0.5, travel) - roadCurve(0.0, travel)) * z * 2.0;
}

fragment float4 driveFragment(QuadOut in [[stage_in]],
                              constant Uniforms &u [[buffer(0)]],
                              texture2d<float> specTex [[texture(0)]]) {
    float2 uv = (fragCoord(in.position, u) - 0.5 * u.res) / u.res.y;
    float travel = u.phase * 9.0 + u.time * 6.0;
    float3 col;
    float y = uv.y - DRIVE_HORIZON;
    float3 horizonGlow = float3(1.0, 0.36, 0.42);
    if (y > 0.0) {
        float3 top = float3(0.03, 0.015, 0.09), mid = float3(0.32, 0.06, 0.38);
        col = mix(horizonGlow * 0.9, mid, smoothstep(0.0, 0.16, y));
        col = mix(col, top, smoothstep(0.12, 0.5, y));
        float2 sid = floor(uv * 180.0);
        float sh = hash2(sid);
        col += float3(1.0) * step(0.993, sh) * smoothstep(0.15, 0.45, y) * (0.5 + 0.5 * sin(u.time * 2.0 + sh * 60.0));
        float2 sc = float2(0.0, DRIVE_HORIZON + 0.16);
        float sr = 0.21 + 0.006 * u.beat;
        float d = length(uv - sc);
        float sunMask = 1.0 - smoothstep(sr - 0.002, sr + 0.002, d);
        float yy = (uv.y - sc.y) / sr;
        float stripe = 1.0;
        if (yy < 0.1) {
            float band = fract((0.1 - yy) * 7.0 * 1.6 - u.time * 0.25);
            stripe = band > min(0.8, (0.1 - yy) * 1.3) ? 1.0 : 0.0;
        }
        float3 sunCol = mix(float3(1.0, 0.22, 0.55), float3(1.0, 0.86, 0.32), smoothstep(-0.9, 0.8, yy));
        col = mix(col, sunCol * 1.1, sunMask * stripe);
        col += sunCol * exp(-max(d - sr, 0.0) * 9.0) * (0.3 + 0.4 * u.bass);
        for (int l = 0; l < 2; l++) {
            float fl = float(l);
            float x = uv.x * (1.0 + fl * 0.6) + fl * 3.0;
            float h = (0.035 + 0.05 * fl) * (0.5 + gnoise(float2(x * 3.0, fl * 5.0)) + 0.35 * gnoise(float2(x * 9.0, fl)));
            h *= 1.0 - fl * 0.25;
            if (y < h) {
                col = mix(float3(0.05, 0.01, 0.10), float3(0.12, 0.02, 0.18), fl) * (0.6 + 0.4 * (1.0 - y / max(h, 1e-3)));
            }
            col += float3(1.0, 0.3, 0.7) * exp(-abs(y - h) * 500.0) * (0.25 + 0.3 * u.treble) * (1.0 - fl * 0.5);
        }
    } else {
        float z = DRIVE_CAMH * DRIVE_FOCAL / max(-y, 1e-4);
        float x = uv.x * z / DRIVE_FOCAL;
        float rx = x - curveRel(z, travel);
        float roadW = 1.55;
        float fog = 1.0 - exp(-z * 0.035);
        float gx = abs(fract(rx * 0.5) - 0.5), gz = abs(fract((z + travel) * 0.25) - 0.5);
        float fw = fwidth(rx * 0.5) + fwidth((z + travel) * 0.25);
        float grid = (1.0 - smoothstep(0.0, fw * 1.5 + 0.01, gx)) + (1.0 - smoothstep(0.0, fw * 1.5 + 0.01, gz));
        col = float3(0.025, 0.006, 0.05) + float3(0.9, 0.15, 0.85) * grid * 0.6 * (0.6 + 0.6 * u.treble) * (1.0 - fog);
        if (abs(rx) < roadW) {
            float3 asphalt = float3(0.035, 0.03, 0.05) + horizonGlow * 0.12 * exp(-abs(rx) * 1.2) * (1.0 - fog * 0.5);
            float dash = step(0.55, fract((z + travel) * 0.3)) * (1.0 - smoothstep(0.03, 0.06, abs(rx)));
            float edge = 1.0 - smoothstep(0.03, 0.07, abs(abs(rx) - roadW + 0.12));
            col = asphalt + float3(1.0, 0.9, 0.7) * dash * 0.9 + float3(0.2, 0.85, 1.0) * edge * (0.9 + 1.2 * u.bass);
        }
        col += float3(1.0, 0.95, 0.85) * 0.18 * exp(-pow(rx * 0.9, 2.0)) * exp(-pow((z - 7.0) * 0.18, 2.0));
        col = mix(col, horizonGlow * 0.55, fog);
    }
    for (int i = 0; i < 9; i++) {
        float fi = float(i);
        float spacing = 9.0;
        float z = fi * spacing + spacing - (travel - spacing * floor(travel / spacing)) + 3.0;
        float cx = curveRel(z, travel);
        for (int sgn = -1; sgn <= 1; sgn += 2) {
            float side = float(sgn);
            float lx = cx + side * 2.4;
            float2 base = float2(lx / z * DRIVE_FOCAL, DRIVE_HORIZON - DRIVE_CAMH * DRIVE_FOCAL / z);
            float2 top = float2((lx - side * 0.4) / z * DRIVE_FOCAL, DRIVE_HORIZON + (2.3 - DRIVE_CAMH) * DRIVE_FOCAL / z);
            float pw = 0.015 / z;
            float2 pa = uv - base, ba = top - base;
            float hseg = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
            float dpole = length(pa - ba * hseg);
            col = mix(col, float3(0.02, 0.015, 0.04), (1.0 - smoothstep(pw, pw * 1.6, dpole)) * (1.0 - smoothstep(30.0, 70.0, z)));
            float dl = length(uv - top);
            float bulb = 0.036 / z;
            col += float3(1.0, 0.75, 0.45) * (exp(-dl * dl / (bulb * bulb)) * 2.5 + exp(-dl / (bulb * 4.0)) * 0.25) * (0.8 + 0.6 * u.beat) * (1.0 - smoothstep(35.0, 80.0, z));
        }
    }
    return float4(col, 1.0);
}
"""#
}
