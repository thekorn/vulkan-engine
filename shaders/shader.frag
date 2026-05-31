#version 450

layout (location = 0) in vec3 fragColor;
layout (location = 1) in vec3 fragPosWorld;
layout (location = 2) in vec3 fragNormalWorld;
layout (location = 3) in vec2 fragUv;
layout (location = 4) in vec4 fragTangentWorld;

layout (location = 0) out vec4 outColor;

struct PointLight {
    vec4 position; // ignore w
    vec4 color;    // w is intensity
};

layout(set = 0, binding = 0) uniform GlobalUbo {
    mat4 projection;
    mat4 view;
    mat4 invView;
    vec4 ambientLightColor; // w is intensity
    PointLight pointLights[10];
    int numLights;
} ubo;

// Per-object material textures bound at set = 1 by
// `SimpleRenderSystem.renderGameObjects`. Objects without a named
// diffuse / normal texture get a 1×1 white / 1×1 flat-normal
// (128, 128, 255) fallback respectively, so the shader path is
// uniform regardless of whether the object opts in to materials.
layout(set = 1, binding = 0) uniform sampler2D diffuseMap;
layout(set = 1, binding = 1) uniform sampler2D normalMap;

layout(push_constant) uniform Push {
    mat4 modelMatrix;
    mat4 normalMatrix;
} push;

void main() {
    // Reconstruct the world-space TBN basis. The tangent was
    // transformed by the model matrix in the vertex shader so it
    // tracks the surface even under non-uniform scaling; Gram-Schmidt
    // re-orthogonalizes it against the (already inverse-transposed)
    // normal here. The handedness sign for the bitangent comes from
    // the mesh's pre-computed tangent.w.
    vec3 N = normalize(fragNormalWorld);
    vec3 T = normalize(fragTangentWorld.xyz - N * dot(N, fragTangentWorld.xyz));
    vec3 B = cross(N, T) * fragTangentWorld.w;
    mat3 TBN = mat3(T, B, N);

    // Decode the tangent-space normal (RGB 0..1 -> -1..1) and rotate
    // it into world space. The flat-normal fallback (128, 128, 255)
    // decodes to (0, 0, 1), so untextured objects come out with the
    // original interpolated normal — same look as before normal
    // mapping was wired up.
    vec3 sampledNormalTS = texture(normalMap, fragUv).xyz * 2.0 - 1.0;
    vec3 surfaceNormal = normalize(TBN * sampledNormalTS);

    vec3 diffuseLight = ubo.ambientLightColor.xyz * ubo.ambientLightColor.w;
    vec3 specularLight = vec3(0.0);

    vec3 cameraPosWorld = ubo.invView[3].xyz;
    vec3 viewDirection = normalize(cameraPosWorld - fragPosWorld);

    for (int i = 0; i < ubo.numLights; i++) {
        PointLight light = ubo.pointLights[i];
        vec3 directionToLight = light.position.xyz - fragPosWorld;
        float attenuation = 1.0 / dot(directionToLight, directionToLight); // distance squared
        directionToLight = normalize(directionToLight);

        float cosAngIncidence = max(dot(surfaceNormal, directionToLight), 0);
        vec3 intensity = light.color.xyz * light.color.w * attenuation;

        diffuseLight += intensity * cosAngIncidence;

        // specular lighting (Blinn-Phong half-angle)
        vec3 halfAngle = normalize(directionToLight + viewDirection);
        float blinnTerm = dot(surfaceNormal, halfAngle);
        blinnTerm = clamp(blinnTerm, 0, 1);
        blinnTerm = pow(blinnTerm, 512.0); // higher values -> sharper highlight
        specularLight += intensity * blinnTerm;
    }

    // Modulate by the sampled diffuse texture so the floor picks up
    // the stone albedo while objects with the default 1×1 white
    // fallback texture (multiplier == 1) are visually unchanged.
    vec3 materialColor = fragColor * texture(diffuseMap, fragUv).rgb;
    outColor = vec4((diffuseLight + specularLight) * materialColor, 1.0);
}
