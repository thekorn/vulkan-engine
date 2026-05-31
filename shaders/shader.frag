#version 450

layout (location = 0) in vec3 fragColor;
layout (location = 1) in vec3 fragPosWorld;
layout (location = 2) in vec3 fragNormalWorld;
layout (location = 3) in vec2 fragUv;

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

// Per-object material texture, bound at set = 1, binding = 0 by
// `SimpleRenderSystem.renderGameObjects` (the descriptor set is
// stored on each `GameObject` as `textureDescriptorSet`). Objects
// without a `textureName` get a 1×1 white fallback, so multiplying
// `fragColor` by the sampled RGB leaves their look unchanged.
layout(set = 1, binding = 0) uniform sampler2D diffuseMap;

layout(push_constant) uniform Push {
    mat4 modelMatrix;
    mat4 normalMatrix;
} push;

void main() {
    vec3 diffuseLight = ubo.ambientLightColor.xyz * ubo.ambientLightColor.w;
    vec3 specularLight = vec3(0.0);
    vec3 surfaceNormal = normalize(fragNormalWorld);

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
