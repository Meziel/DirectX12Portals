#include "Common.hlsli"
#include "RandomNumberGenerator.hlsli"

StructuredBuffer<VertexData> vertices : register(t0);
StructuredBuffer<int> indices : register(t1);
RaytracingAccelerationStructure SceneBVH : register(t2);

float3 RandomUnitVector(float2 random)
{
    // Generate the azimuthal angle (phi), 2pi radians around
    float phi = 2.0 * PI * random.x;

    // Generate the polar angle (theta)
    float theta = acos(2.0 * random.y - 1.0);

    // Convert from spherical to Cartesian coordinates
    float3 unitVector;
    unitVector.x = sin(theta) * cos(phi);
    unitVector.y = sin(theta) * sin(phi);
    unitVector.z = cos(theta);

    return unitVector;
}

float3 RandomUnitVectorHemisphere(float2 random, float3 normal)
{
    // Make sure random.y is in the range [0, 0.5] to generate a point in a hemisphere
    random.y *= 0.5;

    // Generate the azimuthal angle (phi), 2pi radians around
    float phi = 2.0 * 3.14159265358979323846 * random.x;

    // Generate the polar angle (theta)
    float theta = acos(1.0 - random.y);

    // Convert from spherical to Cartesian coordinates
    float3 unitVector;
    unitVector.x = sin(theta) * cos(phi);
    unitVector.y = sin(theta) * sin(phi);
    unitVector.z = cos(theta);

    // Create a rotation matrix that aligns the z-axis with the normal
    float3 up = abs(normal.z) < 0.999 ? float3(0, 0, 1) : float3(1, 0, 0);
    float3 right = normalize(cross(up, normal));
    up = cross(normal, right);

    float3x3 rotationMatrix = float3x3(right, up, normal);

    // Rotate the vector by the matrix
    unitVector = mul(unitVector, rotationMatrix);

    return unitVector;
}

[shader("closesthit")] 
void ClosestHit(inout HitInfo payload, Attributes attrib)
{
    // TODO: move to constant
    float3 lightPos = float3(0, 52.4924, 0);
    float lightIntensity = 1500;
    
    float3 worldHit = WorldRayOrigin() + RayTCurrent() * WorldRayDirection();
    float3 lightDirection = normalize(lightPos - worldHit);
    float lightDistance = length(lightPos - worldHit);
    
    float3 barycentrics = float3(1 - attrib.bary.x - attrib.bary.y, attrib.bary.x, attrib.bary.y);
    uint vertId = 3 * PrimitiveIndex();
    
    float bsdf = 1 / (2 * PI);
    
    VertexData vertexHitData[3] =
    {
        vertices[indices[vertId + 0]],
            vertices[indices[vertId + 1]],
            vertices[indices[vertId + 2]]
    };
    
    float3 hitColor = vertexHitData[0].Color.rgb * barycentrics.x +
                          vertexHitData[1].Color.rgb * barycentrics.y +
                          vertexHitData[2].Color.rgb * barycentrics.z;
    
    float3 hitNormal = vertexHitData[0].Normal.rgb * barycentrics.x +
                           vertexHitData[1].Normal.rgb * barycentrics.y +
                           vertexHitData[2].Normal.rgb * barycentrics.z;
    
    float3 hitEmissive = vertexHitData[0].Emission.rgb * barycentrics.x +
                           vertexHitData[1].Emission.rgb * barycentrics.y +
                           vertexHitData[2].Emission.rgb * barycentrics.z;
    
    payload.Li = hitEmissive * lightIntensity;
    
    //float attenuation = saturate(1.0f - (lightDistance / lightRadius));
    
    // Fire a shadow ray. The direction is hard-coded here, but can be fetched
    // from a constant-buffer 
    //{
    //    RayDesc ray;
    //    ray.Origin = worldHit;
    //    ray.Direction = lightDirection;
    //    ray.TMin = 0.01;
    //    ray.TMax = lightDistance - 0.001;
 

    //    ShadowHitInfo shadowPayload;
    
    //    // Trace the ray
    //    TraceRay(
    //      SceneBVH,
    //      RAY_FLAG_NONE,
    //      0xFF,
    //      1, // Shadow ray type
    //      2, // Hit group stride
    //      1, // Miss shadow ray type
    //      ray,
    //      shadowPayload);
    
    //    float shadowColorFactor = shadowPayload.isHit ? 0.2 : 1.0;
    
    //    float n_dot_l = max(dot(lightDirection, hitNormal), 0);
    
    //    payload.Li += float3(
    //        bsdf * hitColor * shadowColorFactor * n_dot_l * 4 * PI);
    //}
    
    {
        if (payload.Depth >= MAX_DEPTH)
        {
            return;
        }
        
        uint rngState = RNG::SeedThread(payload.Depth * MAX_DEPTH
                                        + payload.Sample * MAX_SAMPLES);
        
        float randomX = RNG::Random01(rngState);
        rngState += 1;
        float randomY = RNG::Random01(rngState);
        
        // TODO: importance sampling
        //float stddev = 1 / 360;
        //float mean = 0;
        
        //// Use Box-Muller transform to generate Gaussian distributed numbers
        //float2 norm = sqrt(-2.0 * log(randomX)) * float2(cos(2.0 * PI * randomY), sin(2.0 * PI * randomY));

        //// Apply mean and standard deviation
        //norm *= stddev;
        //norm += mean;
        
        //float3 randomRayOffset = float3(randomX, randomY, randomZ);
        //float3 randomRayDirection = lightDirection + randomRayOffset;
        
        float3 randomRayDirection = RandomUnitVectorHemisphere(float2(randomX, randomY), hitNormal);
        
        static const int NUM_RAY_DIRECTION = 1;
        float3 rayDirections[] =
        {
            randomRayDirection
            //reflect(WorldRayDirection(), hitNormal),
            //lightDirection,
        };
    
        HitInfo liPayload;
        liPayload.Depth = payload.Depth + 1;
        liPayload.Sample = payload.Sample;
        
        RayDesc ray;
        ray.Origin = worldHit;
        ray.TMin = 0.01;
        ray.TMax = 100000;
    
        float bsdfReflection = bsdf * 0.1;
        
        [unroll]
        for (int i = 0; i < NUM_RAY_DIRECTION; ++i)
        {
            ray.Direction = rayDirections[i];
        
            TraceRay(
            SceneBVH, // Acceleration Structure
            RAY_FLAG_NONE,
            0xFF,
            0, // Normal ray type
            2, // Hit group stride
            0, // Miss normal ray type 
            ray,
            liPayload);
            
            float n_dot_r = max(dot(ray.Direction, hitNormal), 0);
            
            float3 irradience = liPayload.Li * n_dot_r;
            
            payload.Li += bsdfReflection * hitColor * irradience * (2 * PI);
        }
    }
}
