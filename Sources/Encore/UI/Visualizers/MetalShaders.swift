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
// A living glass orb: an iridescent shell whose surface ripples with the
// spectrum, a swirling nebula inside, sparks in orbit and a soft reflection.

static float orbMap(float3 p, float R, float t, float level, constant Uniforms &u, texture2d<float> specTex) {
    float3 q = p;
    q.xz = rot(t * 0.21) * q.xz;
    q.yz = rot(0.35 + 0.1 * sin(t * 0.13)) * q.yz;
    float len = max(length(q), 1e-4);
    float lat = acos(clamp(q.y / len, -1.0, 1.0)) / M_PI_F;
    float lon = atan2(q.z, q.x);
    float s = spec(specTex, abs(lat * 2.0 - 1.0) * 0.9);
    float ridges = 0.5 + 0.5 * sin(lon * 7.0 + lat * 9.0 + t * 1.3);
    float disp = s * 0.07 * ridges * sin(lat * M_PI_F);
    disp += 0.010 * (1.0 + 2.5 * level) * sin(q.x * 4.1 + t * 1.1) * sin(q.y * 3.7 - t * 0.9) * sin(q.z * 4.3 + t * 0.7);
    return (len - R - disp) * 0.6;
}

static float4 orbScene(float2 fc, constant Uniforms &u, texture2d<float> specTex) {
    float2 uv = (fc - 0.5 * u.res) / u.res.y - float2(0.0, 0.07);
    float t = u.time;
    float R = 0.40 + 0.035 * u.bass + 0.03 * u.beat;
    float3 ro = float3(0.0, 0.0, 3.2);
    float3 rd = normalize(float3(uv, -2.0));
    // backdrop: deep gradient, a coloured haze behind the orb and drifting dust
    float3 col = mix(u.shadow.rgb * 0.6, u.p2.rgb * 0.07, smoothstep(-0.6, 0.7, uv.y));
    col += pal(u, 0.25 + uv.x * 0.3) * exp(-length(uv) * 2.2) * 0.16 * (0.6 + u.level);
    for (int i = 0; i < 2; i++) {
        float fi = float(i);
        float2 g = (uv + float2(t * 0.006 * (fi + 1.0), t * 0.004)) * (14.0 + fi * 10.0);
        float2 id = floor(g);
        float2 f = fract(g) - 0.5;
        float h = hash2(id + fi * 7.0);
        float2 o = float2(hash2(id + 1.3), hash2(id + 2.7)) - 0.5;
        col += pal(u, h) * (1.0 - smoothstep(0.0, 0.06, length(f - o * 0.7))) * step(0.88, h) * (0.25 + 0.6 * u.treble);
    }
    float b = dot(ro, rd);
    float dRay = sqrt(max(dot(ro, ro) - b * b, 0.0));
    float Rb = R + 0.16;
    float disc = b * b - (dot(ro, ro) - Rb * Rb);
    bool hit = false;
    float tt = 0.0;
    if (disc > 0.0) {
        tt = max(-b - sqrt(disc), 0.0);
        float tmax = -b + sqrt(disc);
        for (int i = 0; i < 70; i++) {
            float d = orbMap(ro + rd * tt, R, t, u.level, u, specTex);
            if (d < 0.0012) { hit = true; break; }
            tt += d;
            if (tt > tmax) break;
        }
    }
    // halo
    float halo = exp(-max(dRay - R, 0.0) * 11.0) * (0.12 + 0.4 * u.level + 0.3 * u.beat);
    col += pal(u, 0.12 + abs(atan2(uv.y, uv.x)) / 3.1416 * 0.35 + t * 0.02) * halo;
    // reflection on an unseen floor
    col += pal(u, 0.15) * exp(-pow((uv.y + R * 0.98 + 0.06) / 0.025, 2.0)) * exp(-abs(uv.x) / (R * 0.8)) * 0.3 * (0.5 + u.level);
    if (hit) {
        float3 p = ro + rd * tt;
        float2 e = float2(0.003, 0.0);
        float3 n = normalize(float3(orbMap(p + e.xyy, R, t, u.level, u, specTex) - orbMap(p - e.xyy, R, t, u.level, u, specTex),
                                    orbMap(p + e.yxy, R, t, u.level, u, specTex) - orbMap(p - e.yxy, R, t, u.level, u, specTex),
                                    orbMap(p + e.yyx, R, t, u.level, u, specTex) - orbMap(p - e.yyx, R, t, u.level, u, specTex)));
        float facing = max(dot(n, -rd), 0.0);
        float fres = pow(1.0 - facing, 2.5);
        float3 rr = refract(rd, n, 0.8);
        float3 inner = float3(0.0);
        for (int k = 0; k < 7; k++) {
            float3 ip = p + rr * (0.05 + float(k) * R * 0.27);
            float3 iq = ip;
            iq.xz = rot(t * 0.3) * iq.xz;
            float g1 = gnoise(iq.xy * 3.0 + float2(t * 0.25, iq.z * 2.0));
            float g2 = gnoise(iq.yz * 2.6 - float2(t * 0.2, 0.0) + 3.7);
            float dens = pow(g1 * g2 * 2.4, 5.0);
            float core = exp(-length(ip) / R * 2.6);
            inner += pal(u, g1 * 1.4 + float(k) * 0.06 + u.phase * 0.02) * dens * 0.22 + pal(u, 0.1) * core * 0.06 * (0.5 + 1.5 * u.level);
        }
        inner *= 0.6 + 0.8 * u.level + 0.6 * u.beat;
        float3 iri = 0.5 + 0.5 * cos(6.2831 * (fres * 1.1 + n.y * 0.25 + t * 0.04 + float3(0.0, 0.33, 0.67)));
        float3 L1 = normalize(float3(-0.6, 0.7, 0.5));
        float3 L2 = normalize(float3(0.8, 0.25, 0.3));
        float3 rf = reflect(rd, n);
        col = col * 0.15 + u.shadow.rgb * 0.5 + inner * (1.0 - fres * 0.6);
        col += mix(iri, pal(u, 0.3 + n.x * 0.2), 0.35) * fres * 1.1;
        col += float3(1.0) * pow(max(dot(rf, L1), 0.0), 90.0) * 2.5;
        col += pal(u, 0.6) * pow(max(dot(rf, L2), 0.0), 24.0) * 0.5;
    }
    // sparks in orbit
    for (int i = 0; i < 36; i++) {
        float fi = float(i);
        float a = fi / 36.0 * 6.2831 + t * (0.25 + 0.1 * hash1(fi));
        float sv = spec(specTex, fract(fi * 0.37));
        float rad = R * 1.45 + 0.08 * hash1(fi * 3.3) + 0.12 * sv;
        float3 sp = float3(cos(a) * rad, 0.04 * sin(a * 3.0 + t + fi), sin(a) * rad);
        sp.yz = rot(0.42) * sp.yz;
        if (hit && sp.z < 0.0) continue;
        float2 ss = sp.xy * 2.0 / (3.2 - sp.z);
        float d = length(uv - ss);
        col += pal(u, fi / 36.0 + t * 0.03) * exp(-d * d / 0.000012) * (0.6 + 2.2 * sv);
    }
    return float4(col, 1.0);
}

fragment float4 orbFragment(QuadOut in [[stage_in]],
                            constant Uniforms &u [[buffer(0)]],
                            texture2d<float> specTex [[texture(0)]]) {
    return orbScene(fragCoord(in.position, u), u, specTex);
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
    col += mix(float3(1.0), u.p0.rgb, 0.35) * spc * (0.28 + 0.8 * u.level + 0.6 * u.beat);
    col += u.p1.rgb * sheen * 0.30;
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
    col += glowColor(a + t * 0.050) * exp(-d / w1) * 1.0;
    col += glowColor(a - t * 0.035 + 0.33) * exp(-d / w2) * 0.55;
    col += glowColor(a + t * 0.020 + 0.66) * exp(-d / w3) * 0.16;
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

static float3 driveOutside(float2 uv, float t, constant Uniforms &u, texture2d<float> specTex, thread float &pass) {
    float speed = 13.0;
    float dist = t * speed;
    float c = 0.0011 * sin(t * 0.045) + 0.0005 * sin(t * 0.11);
    float camX = -1.75 + 0.12 * sin(t * 0.07);
    float H = 0.03;
    // sky: overcast dusk with a warm city glow at the horizon
    float3 sky = mix(float3(0.30, 0.34, 0.42), float3(0.10, 0.13, 0.19), smoothstep(H, H + 0.45, uv.y));
    sky += float3(1.0, 0.55, 0.3) * exp(-max(uv.y - H, 0.0) * 12.0) * 0.18;
    sky = mix(sky, u.p2.rgb * 0.3 + sky * 0.7, 0.12);
    float3 col = sky;
    // distant skyline
    float bx = floor(uv.x * 22.0 + c * 900.0);
    float bh = 0.02 + 0.09 * hash1(bx * 1.7) * hash1(bx * 0.31 + 2.0);
    if (uv.y > H && uv.y < H + bh) {
        float3 fogged = mix(float3(0.06, 0.07, 0.10), sky, 0.45);
        float2 wg = float2(uv.x * 260.0, (uv.y - H) * 300.0);
        float lit = step(0.72, hash2(floor(wg) + bx)) * step(0.3, fract(wg.x)) * step(0.35, fract(wg.y));
        col = fogged + float3(1.0, 0.75, 0.45) * lit * 0.25;
    }
    // buildings along the street, streaming past
    float side = uv.x < 0.0 ? -1.0 : 1.0;
    float X = side * 10.5;
    float zw = (X - camX) * 0.9 / max(abs(uv.x), 1e-3) * side;
    float yw = 1.25 + (uv.y - H) * zw / 0.9;
    float along = zw + dist;
    float seg = floor(along / 15.0 + side * 3.1);
    float bH = 6.0 + 16.0 * hash1(seg * 1.31 + side);
    float gap = step(fract(along / 15.0 + side * 3.1), 0.07);
    if (zw > 0.0 && yw > 0.0 && yw < bH && gap < 0.5) {
        float near = smoothstep(2.0, 9.0, zw);
        float3 wall = float3(0.025, 0.027, 0.036) + float3(0.03, 0.022, 0.015) * hash1(seg);
        float2 wc = float2(along / 2.3, yw / 2.1);
        float2 wf = fract(wc);
        float soft = 0.16 + 0.25 * (1.0 - near);
        float win = smoothstep(0.2 - soft, 0.2 + soft, wf.x) * (1.0 - smoothstep(0.75 - soft, 0.75 + soft, wf.x))
                  * smoothstep(0.3 - soft, 0.3 + soft, wf.y) * (1.0 - smoothstep(0.78 - soft, 0.78 + soft, wf.y));
        float hw = hash2(floor(wc) + seg);
        float3 wcol = mix(float3(1.0, 0.72, 0.42), float3(0.75, 0.88, 1.0), step(0.75, hash1(hw * 13.0)));
        float lit = step(0.62, hw) * (0.25 + 0.6 * hash1(hw * 7.0));
        float shop = 1.0 - smoothstep(2.6, 3.2, yw);
        float3 shopCol = mix(float3(1.0, 0.8, 0.55), pal(u, hash1(seg * 3.0)), 0.35) * (0.5 + 0.4 * spec(specTex, 0.3 + 0.4 * hash1(seg)));
        wall += wcol * win * lit * 0.55 * near;
        wall = mix(wall, shopCol * 0.8, shop * smoothstep(0.4, 1.2, yw) * mix(0.35, 1.0, near));
        wall = mix(wall, float3(0.05, 0.05, 0.06), (1.0 - near) * 0.5);
        col = mix(wall, sky, 1.0 - exp(-zw * 0.012));
    } else if (uv.y < H) {
        // wet road
        float z = 1.25 * 0.9 / max(H - uv.y, 1e-4);
        float xw = uv.x * z / 0.9 + camX - drvCurve(z, c);
        float zr = z + dist;
        float3 road = float3(0.035, 0.038, 0.045) + fbm3(float2(xw, zr) * 0.8) * 0.02;
        float lw = 0.07 + z * 0.002;
        float m = (1.0 - smoothstep(lw, lw * 2.5, abs(xw + 3.5))) * step(fract(zr / 9.0), 0.4);
        m += (1.0 - smoothstep(lw, lw * 2.5, abs(xw)));
        m += (1.0 - smoothstep(lw, lw * 2.5, abs(abs(xw) - 7.0)));
        road += float3(0.8, 0.8, 0.72) * m * exp(-z * 0.03) * 0.25;
        float walk = smoothstep(7.2, 7.6, abs(xw));
        road = mix(road, float3(0.06, 0.06, 0.07), walk);
        // pools of light under the street lamps
        for (int k = 0; k < 5; k++) {
            float lz = (float(k) + 1.0) * 24.0 - fmod(dist, 24.0);
            float pl = exp(-((abs(xw) - 6.0) * (abs(xw) - 6.0)) * 0.04 - (z - lz) * (z - lz) * 0.012);
            road += float3(1.0, 0.6, 0.28) * pl * 0.22;
        }
        col = mix(road, sky * 0.9, 1.0 - exp(-z * 0.015));
    }
    float ground = 1.0 - smoothstep(H - 0.01, H + 0.002, uv.y);
    // street lamps
    for (int k = 0; k < 7; k++) {
        for (int s = 0; s < 2; s++) {
            float sd = s == 0 ? -1.0 : 1.0;
            float lz = (float(k) + 1.0) * 24.0 - fmod(dist + (sd > 0.0 ? 12.0 : 0.0), 24.0);
            if (lz < 1.2) continue;
            float3 w = float3(sd * 8.0, 6.5, lz);
            float r = 0.010 + 0.28 / lz;
            float3 lc = float3(1.0, 0.6, 0.27) * (1.0 + 0.5 * spec(specTex, 0.1 + 0.08 * float(k)));
            col += drvBokeh(uv, drvProject(w, c, camX), r, lc);
            col += drvStreak(uv, drvProject(float3(w.x, -w.y, w.z), c, camX), r, lc) * ground;
            pass += exp(-lz * 0.22);
        }
    }
    // the car ahead: dark silhouette, tail lights brake with the bass
    float zc = 14.0 + 3.0 * sin(t * 0.17);
    float xc = -1.75 + 0.25 * sin(t * 0.11);
    float2 cpos = drvProject(float3(xc, 0.85, zc), c, camX);
    float sc = 0.9 / zc;
    float body = sdBox(uv - cpos, float2(0.95, 0.6) * sc, 0.25 * sc);
    float roof = sdBox(uv - cpos - float2(0.0, 0.75) * sc, float2(0.7, 0.3) * sc, 0.2 * sc);
    col = mix(col, float3(0.02, 0.02, 0.025), (1.0 - smoothstep(-0.006, 0.01, min(body, roof))) * 0.9);
    float brake = 0.7 + 1.5 * u.bass + 0.8 * u.beat;
    for (int s = 0; s < 2; s++) {
        float sd = s == 0 ? -1.0 : 1.0;
        float3 w = float3(xc + sd * 0.72, 0.95, zc);
        float r = 0.010 + 0.2 / zc;
        col += drvBokeh(uv, drvProject(w, c, camX), r, float3(1.0, 0.08, 0.06) * brake);
        col += drvStreak(uv, drvProject(float3(w.x, -w.y, w.z), c, camX), r, float3(1.0, 0.08, 0.06) * brake) * ground;
    }
    col += float3(0.9, 0.9, 1.0) * exp(-length((uv - cpos - float2(0.0, -0.25) * sc) / float2(0.25 * sc, 0.08 * sc))) * 0.12;
    // more traffic ahead in the next lane
    for (int i = 0; i < 2; i++) {
        float fi = float(i);
        float z2 = 24.0 + fmod(t * 2.2 + fi * 37.0, 70.0);
        for (int s = 0; s < 2; s++) {
            float3 w = float3(-5.25 + (float(s) * 2.0 - 1.0) * 0.72, 0.95, z2);
            col += drvBokeh(uv, drvProject(w, c, camX), 0.009 + 0.2 / z2, float3(1.0, 0.1, 0.07) * 0.9);
            col += drvStreak(uv, drvProject(float3(w.x, -w.y, w.z), c, camX), 0.009 + 0.2 / z2, float3(1.0, 0.1, 0.07) * 0.9) * ground;
        }
    }
    // oncoming headlights with anamorphic glare
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float z3 = 150.0 - fmod(t * 30.0 + fi * 53.0, 150.0);
        if (z3 < 2.0) continue;
        float lane = i == 1 ? 5.25 : 1.75;
        float boost = 1.0 + 7.0 / z3;
        for (int s = 0; s < 2; s++) {
            float3 w = float3(lane + (float(s) * 2.0 - 1.0) * 0.7, 0.7, z3);
            float2 sp = drvProject(w, c, camX);
            float r = 0.010 + 0.22 / z3;
            float3 lc = float3(0.85, 0.92, 1.0) * boost;
            col += drvBokeh(uv, sp, r, lc);
            col += drvStreak(uv, drvProject(float3(w.x, -w.y, w.z), c, camX), r, lc) * ground;
            col += lc * exp(-abs(uv.y - sp.y) * 260.0) * exp(-abs(uv.x - sp.x) * 4.0) * 0.06 * min(boost, 3.0);
        }
        pass += exp(-z3 * 0.15) * 0.6;
    }
    // neon signs in the artwork's colours, pulsing with the music
    for (int k = 0; k < 4; k++) {
        float fk = float(k);
        float sd = fmod(fk, 2.0) < 0.5 ? -1.0 : 1.0;
        float nz = (fk + 1.0) * 31.0 - fmod(dist + fk * 9.0, 31.0 * 4.0) ;
        if (nz < 3.0) nz += 124.0;
        float3 w = float3(sd * 9.6, 3.6 + fmod(fk, 3.0), nz);
        float3 lc = pal(u, fk * 0.3 + 0.1) * (0.8 + 1.4 * spec(specTex, 0.2 + fk * 0.15));
        float2 sp = drvProject(w, c, camX);
        float r = 0.008 + 0.25 / nz;
        col += drvBokeh(uv, sp, r, lc) + drvBokeh(uv, sp + float2(sd * r * 1.6, 0.0), r, lc * 0.8);
        col += drvStreak(uv, drvProject(float3(w.x, -w.y, w.z), c, camX), r * 1.5, lc) * ground;
    }
    // far city lights
    for (int i = 0; i < 16; i++) {
        float fi = float(i);
        float2 cp = float2((hash1(fi * 1.7) - 0.5) * 1.6 + c * 900.0 * 0.0, H + 0.005 + 0.07 * hash1(fi * 4.4));
        float3 lc = mix(float3(1.0, 0.65, 0.3), float3(0.8, 0.9, 1.0), step(0.6, hash1(fi * 8.1)));
        col += drvBokeh(uv, cp, 0.006 + 0.008 * hash1(fi * 2.9), lc * (0.3 + 0.5 * spec(specTex, 0.6 + 0.3 * hash1(fi))));
    }
    return col;
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
            float2 o = (float2(hash2(id + 1.7), hash2(id + 4.3)) - 0.5) * 0.6;
            float r = 0.16 + 0.22 * fract(h * 17.0);
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
    return float3(off, max(mask, trail * 0.5));
}

static float4 driveScene(float2 fc, constant Uniforms &u, texture2d<float> specTex) {
    float2 uv = (fc - 0.5 * u.res) / u.res.y;
    float aspect = u.res.x / u.res.y;
    float t = u.time;
    float px = 1.0 / u.res.y;
    #define AA(d) clamp(0.5 - (d) / px, 0.0, 1.0)
    // the road moves under the car: gentle sway and vibration
    float2 sway = float2(0.003 * sin(t * 0.9), 0.0012 * sin(t * 7.3) * (0.5 + u.bass) + 0.0015 * sin(t * 1.7));
    float blade;
    float since = drvWipe(uv, t, blade);
    float3 r = driveRain(uv, t, since);
    float pass = 0.0;
    float dummy = 0.0;
    float3 view = driveOutside(uv + sway + r.xy * 3.0, t, u, specTex, pass);
    if (r.z > 0.01) {
        float3 sharp = driveOutside(uv + sway - r.xy * 6.0, t, u, specTex, dummy);
        view = mix(view, sharp * 1.1 + 0.03, r.z * 0.8);
    }
    view *= (0.85 + 0.15 * (1.0 - r.z)) * 0.92;
    float3 col = view;
    // wiper blades
    col = mix(col, float3(0.012), AA(blade));
    // light from passing street lamps and oncoming cars washes over the cabin
    float3 cabinLight = float3(1.0, 0.62, 0.32) * min(pass, 2.0) * 0.06;
    float3 trim = float3(0.028, 0.026, 0.032) + cabinLight * 0.6;
    // roof
    float roofY = 0.36 - 0.05 * uv.x * uv.x;
    col = mix(col, mix(float3(0.07, 0.068, 0.075) + cabinLight, float3(0.03), smoothstep(roofY, 0.5, uv.y)), smoothstep(roofY - 0.004, roofY + 0.004, uv.y));
    // A-pillars
    for (int sgn = -1; sgn <= 1; sgn += 2) {
        float sx = float(sgn);
        float edge = 0.5 * aspect - 0.12 - (0.36 - uv.y) * 0.28;
        float pillar = smoothstep(edge - 0.004, edge + 0.004, sx * uv.x);
        col = mix(col, trim * (1.0 + 0.4 * smoothstep(0.0, 0.1, sx * uv.x - edge)), pillar);
    }
    // rear-view mirror and dash cam
    col = mix(col, trim, AA(sdBox(uv - float2(0.0, 0.335), float2(0.012, 0.03), 0.004)));
    float mirror = sdBox(uv - float2(0.0, 0.27), float2(0.165, 0.042), 0.035);
    if (mirror < 0.01) {
        float3 behind = driveOutside(float2(-uv.x * 1.5, 0.12 + (uv.y - 0.27) * 2.0), t + 40.0, u, specTex, dummy) * 0.35;
        float3 mirrorCol = mix(float3(0.02) + cabinLight * 0.3, behind, step(mirror, -0.008));
        col = mix(col, mirrorCol, AA(mirror));
    }
    col = mix(col, trim * 0.8, AA(sdBox(uv - float2(-0.08, 0.215), float2(0.022, 0.026), 0.005)));
    col += float3(0.1, 0.6, 1.0) * exp(-length(uv - float2(-0.08, 0.21)) * 900.0) * (0.5 + 0.5 * step(0.5, fract(t * 0.5)));
    // dashboard
    float dashY = -0.07 - 0.03 * uv.x * uv.x;
    float dash = 1.0 - smoothstep(dashY - 0.004, dashY + 0.004, uv.y);
    float3 dashCol = mix(float3(0.045, 0.042, 0.05), float3(0.018, 0.017, 0.02), 1.0 - smoothstep(dashY - 0.2, dashY, uv.y)) + fbm3(uv * 120.0) * 0.012;
    dashCol += cabinLight * smoothstep(dashY - 0.25, dashY, uv.y);
    dashCol += float3(0.25, 0.3, 0.35) * exp(-abs(uv.y - dashY) * 120.0) * 0.15;
    // a reflection of the windshield on the top of the dash
    dashCol += view * 0.08 * smoothstep(dashY - 0.05, dashY, uv.y);
    // ambient light strip in the artwork's colour
    dashCol += u.p1.rgb * exp(-abs(uv.y - (dashY - 0.03)) * 500.0) * (0.25 + 0.6 * u.level) * (1.0 - smoothstep(0.35, 0.5, abs(uv.x)));
    col = mix(col, dashCol, dash);
    // vents
    for (int sgn = -1; sgn <= 1; sgn += 2) {
        float2 vc = float2(float(sgn) * 0.255, -0.16);
        float vent = sdBox(uv - vc, float2(0.045, 0.06), 0.012);
        float slats = 0.5 + 0.5 * sin((uv.y - vc.y) * 260.0);
        col = mix(col, mix(float3(0.01), float3(0.06) + cabinLight * 0.5, slats), AA(vent));
        col += float3(0.6, 0.62, 0.66) * (1.0 - smoothstep(0.0, 0.003, abs(vent))) * 0.35;
    }
    // dashboard screen: old-radio LED bars in the lower half (title drawn natively above)
    float2 sc = float2(0.0, -0.17);
    float2 sh = float2(0.19, 0.08);
    float scr = sdBox(uv - sc, sh, 0.012);
    col = mix(col, float3(0.5), (1.0 - smoothstep(0.0, 0.004, abs(scr + 0.002))) * 0.25);
    if (scr < 0.0) {
        float2 q = (uv - sc) / sh;
        float3 sbg = mix(float3(0.02, 0.03, 0.06), float3(0.04, 0.03, 0.08), q.y * 0.5 + 0.5);
        float bars = 20.0;
        float segs = 9.0;
        float bx = (q.x * 0.5 + 0.5) * bars;
        float bi = floor(bx);
        float bf = fract(bx);
        float v = spec(specTex, bi / bars * 0.9);
        float yy = (q.y + 0.9) / 0.95 * segs;
        float si = floor(yy);
        float sf = fract(yy);
        if (yy > 0.0 && yy < segs && bf > 0.12 && bf < 0.88 && sf > 0.14 && sf < 0.86) {
            float3 lc = si < 5.0 ? float3(0.25, 1.0, 0.45) : (si < 7.0 ? float3(1.0, 0.78, 0.15) : float3(1.0, 0.22, 0.18));
            sbg += lc * (step(si + 0.5, v * segs * 1.1) * 1.4 + 0.06);
        }
        sbg += float3(1.0) * pow(max(0.0, 1.0 - abs(q.x + q.y * 0.6 - 0.2)), 12.0) * 0.03;
        col = sbg;
    } else {
        col += float3(0.25, 0.3, 0.6) * exp(-scr * 30.0) * 0.12;
    }
    // instrument cluster (right-hand drive): ticks, glowing arcs, needles
    float2 cl = float2(0.47 * aspect - 0.2, -0.13);
    float clBox = sdBox(uv - cl, float2(0.12, 0.06), 0.03);
    col = mix(col, float3(0.012, 0.014, 0.02), AA(clBox) * 0.9);
    for (int k = 0; k < 2; k++) {
        float2 gc = cl + float2(float(k) * 0.11 - 0.055, 0.0);
        float2 gd = uv - gc;
        float gr = length(gd);
        float ga = atan2(gd.x, gd.y);
        float val = k == 0 ? 0.35 + 0.45 * u.level + 0.1 * sin(t * 0.3) : 0.2 + 0.6 * u.bass;
        float needle = val * 4.0 - 2.0;
        float inArc = step(-2.0, ga) * step(ga, 2.0);
        float ticks = step(0.75, fract((ga + 2.0) / 4.0 * 12.0)) * inArc;
        col += float3(0.7, 0.85, 1.0) * ticks * (1.0 - smoothstep(0.0, 0.002, abs(gr - 0.041))) * 0.7;
        col += float3(0.25, 0.6, 1.0) * (1.0 - smoothstep(0.0, 0.0025, abs(gr - 0.045))) * inArc * 0.5;
        col += mix(float3(0.2, 0.6, 1.0), u.p0.rgb, 0.5) * (1.0 - smoothstep(0.0, 0.004, abs(gr - 0.045))) * step(-2.0, ga) * step(ga, needle) * 0.9;
        float2 nd = float2(sin(needle), cos(needle));
        float al = dot(gd, nd);
        float across = abs(dot(gd, float2(nd.y, -nd.x)));
        col += float3(1.0, 0.35, 0.2) * (1.0 - smoothstep(0.001, 0.0025, across)) * step(0.0, al) * step(al, 0.036) * 1.3;
        col += float3(0.6, 0.65, 0.7) * (1.0 - smoothstep(0.003, 0.005, gr)) * 0.5;
    }
    // steering wheel, turning gently with the road
    float2 wc = float2(0.47 * aspect - 0.2, -0.36);
    float steer = -(0.0011 * sin(t * 0.045) + 0.0005 * sin(t * 0.11)) * 110.0;
    float2 wq = rot(steer) * (uv - wc);
    float wr = length(wq);
    float rim = abs(wr - 0.24) - 0.022;
    float ang = atan2(wq.y, wq.x);
    float3 wheelCol = float3(0.022) + cabinLight * 0.4 + float3(0.5, 0.48, 0.52) * pow(max(0.0, cos(ang - 1.9)), 8.0) * (1.0 - smoothstep(-0.02, 0.02, abs(wr - 0.24) - 0.012)) * 0.35;
    col = mix(col, wheelCol, AA(rim));
    float hub = sdBox(wq, float2(0.09, 0.07), 0.04);
    float spokes = min(sdBox(wq - float2(-0.13, 0.0), float2(0.1, 0.022), 0.01), sdBox(wq - float2(0.13, 0.0), float2(0.1, 0.022), 0.01));
    col = mix(col, float3(0.026) + cabinLight * 0.3, AA(min(hub, spokes)));
    col += float3(0.6, 0.62, 0.68) * (1.0 - smoothstep(0.0, 0.0025, abs(length(wq / float2(1.0, 1.4)) - 0.018))) * 0.4;
    col += u.p1.rgb * 0.01 * (1.0 + u.level);
    #undef AA
    return float4(col, 1.0);
}

fragment float4 driveFragment(QuadOut in [[stage_in]],
                            constant Uniforms &u [[buffer(0)]],
                            texture2d<float> specTex [[texture(0)]]) {
    return driveScene(fragCoord(in.position, u), u, specTex);
}
"""#
}
