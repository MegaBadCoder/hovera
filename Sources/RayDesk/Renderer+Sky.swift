extension Renderer {
    static let skyShaderSource = """

    struct SkyUniforms { float4x4 inverseViewProjection; float4 params; };
    struct SkyOut { float4 position [[position]]; float2 ndc; };

    vertex SkyOut skyVertex(uint vid [[vertex_id]]) {
        const float2 corners[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        SkyOut out;
        out.position = float4(corners[vid], 0, 1);
        out.ndc = corners[vid];
        return out;
    }

    static float hash31(float3 p) {
        p = fract(p * 0.1031);
        p += dot(p, p.zyx + 31.32);
        return fract((p.x + p.y) * p.z);
    }

    static float3 hash33(float3 p) {
        p = fract(p * float3(0.1031, 0.1030, 0.0973));
        p += dot(p, p.yxz + 33.33);
        return fract((p.xxy + p.yxx) * p.zyx);
    }

    static float valueNoise(float3 p) {
        float3 i = floor(p);
        float3 f = fract(p);
        float3 u = f * f * (3 - 2 * f);
        float n000 = hash31(i);
        float n100 = hash31(i + float3(1, 0, 0));
        float n010 = hash31(i + float3(0, 1, 0));
        float n110 = hash31(i + float3(1, 1, 0));
        float n001 = hash31(i + float3(0, 0, 1));
        float n101 = hash31(i + float3(1, 0, 1));
        float n011 = hash31(i + float3(0, 1, 1));
        float n111 = hash31(i + float3(1, 1, 1));
        return mix(mix(mix(n000, n100, u.x), mix(n010, n110, u.x), u.y),
                   mix(mix(n001, n101, u.x), mix(n011, n111, u.x), u.y), u.z);
    }

    static float fbm(float3 p) {
        float sum = 0;
        float amplitude = 0.5;
        for (int i = 0; i < 4; i++) {
            sum += amplitude * valueNoise(p);
            p = p * 2.03 + float3(1.7, 9.2, 3.1);
            amplitude *= 0.5;
        }
        return sum;
    }

    static float3 stars(float3 dir, float scale, float density, float size, float time) {
        float3 cell = floor(dir * scale);
        float3 h = hash33(cell);
        if (h.x > density) { return float3(0); }
        float3 star = normalize(cell + 0.3 + 0.4 * hash33(cell + 17.0));
        float distance = length(dir - star);
        float twinkle = 0.75 + 0.25 * sin(time * (0.7 + 2.5 * h.z) + h.y * 40.0);
        float brightness = (0.08 + 0.92 * pow(h.y, 4.0)) * twinkle;
        float3 tint = mix(float3(0.70, 0.80, 1.00), float3(1.00, 0.86, 0.70), h.z);
        return tint * brightness * exp(-pow(distance / size, 2.0));
    }

    fragment float4 skyFragment(SkyOut in [[stage_in]], constant SkyUniforms &u [[buffer(0)]]) {
        float time = u.params.x;
        float amount = u.params.y;
        float4 world = u.inverseViewProjection * float4(in.ndc, 1, 1);
        float3 dir = normalize(world.xyz / world.w);

        float3 color = float3(0.004, 0.006, 0.016);

        float band = exp(-pow(dot(dir, normalize(float3(0.35, 0.85, 0.25))) / 0.32, 2.0));
        float cloud = fbm(dir * 2.2 + float3(0, 0, time * 0.004));
        float wisps = fbm(dir * 5.0 + float3(11.3, 4.1, time * 0.006));
        float nebula = smoothstep(0.42, 0.85, cloud) * (0.35 + 0.65 * band);
        color += mix(float3(0.05, 0.03, 0.14), float3(0.20, 0.06, 0.24), wisps) * nebula;
        color += float3(0.02, 0.10, 0.13) * smoothstep(0.55, 0.9, wisps) * band * 0.8;

        color += stars(dir, 120.0, 0.10 + 0.25 * band, 0.0008, time) * 1.6;
        color += stars(dir, 45.0, 0.07, 0.0014, time) * 2.2;

        float3 planetCenter = normalize(float3(0.35, -0.55, -0.75));
        float planetRadius = 0.36;
        float angle = acos(clamp(dot(dir, planetCenter), -1.0, 1.0));
        if (angle < planetRadius) {
            float3 east = normalize(cross(planetCenter, float3(0, 1, 0)));
            float3 north = cross(east, planetCenter);
            float2 local = float2(dot(dir, east), dot(dir, north)) / sin(planetRadius);
            float3 normal = float3(local, sqrt(max(0.0, 1.0 - dot(local, local))));
            float light = max(0.0, dot(normal, normalize(float3(-0.55, 0.55, 0.62))));
            float bands = fbm(float3(local.x * 2.0, local.y * 9.0, 3.0) + time * 0.002);
            float3 surface = mix(float3(0.05, 0.10, 0.22), float3(0.22, 0.34, 0.52), bands);
            color = surface * (0.04 + 0.9 * light);
        }
        float rim = exp(-pow((angle - planetRadius) / 0.018, 2.0));
        color += float3(0.25, 0.50, 1.00) * rim * 0.55;

        float breathing = u.params.z;
        float visibility = u.params.w;
        if (visibility > 0) {
            float fromForward = acos(clamp(dot(dir, float3(0, 0, -1)), -1.0, 1.0));
            float radius = mix(0.05, 0.13, breathing);
            float ring = exp(-pow((fromForward - radius) / 0.006, 2.0));
            float glow = exp(-pow(fromForward / radius, 2.0)) * 0.12;
            color += float3(0.55, 0.85, 1.00) * (ring * 0.9 + glow) * visibility;
        }

        return float4(color * amount, 1);
    }
    """
}
