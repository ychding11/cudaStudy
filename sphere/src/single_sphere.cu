 
#include <iostream>
#include <chrono>  // for high_resolution_clock
#include <cuda_runtime.h>
#include <curand.h>
#include <curand_kernel.h>
#include "device_launch_parameters.h"
#include "helper_string.h"
#include "ray.h"
#include "utility.h"


#define CUDA_CALL_CHECK(x)                             \
do{                                                    \
    cudaError_t cudaStatus = x;                        \
    if((cudaStatus) != cudaSuccess)                    \
    {                                                  \
        printf("Error at %s:%d\t",__FILE__,__LINE__);  \
        printf("%s %d\t",#x, (cudaStatus));            \
        printf("%s\n",cudaGetErrorString(cudaStatus)); \
        system("pause");                               \
        return EXIT_FAILURE;                           \
    }                                                  \
} while(0)


#define M_PI 3.14159265359f  // pi

__device__ float hit_sphere(const ray& r, const vec3& center, float radius)
{
    vec3 oc = r.origin() - center;
    float a = dot(r.direction(), r.direction());
    float b = 2.0f * dot(oc, r.direction());
    float c = dot(oc, oc) - radius * radius;
    float d = b * b - 4.f * a * c;
    if (d < 0.f)
    {
        return -1.f;
    }
    else
    {
        return (-b - sqrt(d)) / (2.f * a);
    }
}

__device__ vec3 color(const ray& r)
{
    vec3 center{ 0.f, 0.f, -2.f };
    float t = hit_sphere(r, center, 0.5f);
    if (t > 0.f)
    {
        vec3 n = unit_vector(r.point_at_parameter(t) - center);
        return 0.5f * vec3(n.x() + 1.f, n.y() + 1.f, n.z() + 1.f);
    }
    else
    {
        vec3 unit_direction = unit_vector(r.direction());
        float t = 0.5*(unit_direction.y() + 1.0);
        return (1.0 - t)*vec3(1.0, 1.0, 1.0) + t*vec3(0.5, 0.7, 1.0);
    }
}

#define SUB_GRID_X 256
#define SUB_GRID_Y 256                
#define BLOCK_X 8
#define BLOCK_Y 8

__global__ void setup_random_kernel(curandState *states, int nx, int ny, int subx = 0, int suby = 0)
{
    unsigned int x = blockIdx.x * blockDim.x + threadIdx.x;
    unsigned int y = blockIdx.y * blockDim.y + threadIdx.y;
    x = SUB_GRID_X * subx + x;
    y = SUB_GRID_Y * suby + y;
    if (x >= nx || y >= ny) return;
    unsigned int i = (ny - y - 1) * nx + x; // index of current pixel (calculated using thread index) 

    curand_init(1234, i, 0, &states[i]);
}

// __global__ : executed on the device (GPU) and callable only from host (CPU) 
__global__ void render_kernel(curandState *states, float* output, int nx, int ny, int ns, int subx = 0, int suby = 0)
{
    unsigned int x = blockIdx.x*blockDim.x + threadIdx.x;
    unsigned int y = blockIdx.y*blockDim.y + threadIdx.y;
    x = SUB_GRID_X * subx + x;
    y = SUB_GRID_Y * suby + y;
    if (x >= nx || y >= ny) return;

    unsigned int i = (ny - y - 1) * nx + x; // index of current pixel (calculated using thread index) 
    float aspect = float(nx) / float(ny);

    vec3 vertical(0.f, 1.f, 0.f);
    vec3 horizonal = vec3{1.f, 0.f, 0.f} * aspect;
    vec3 origin(0.f, 0.f, 0.f);

    curandState localState = states[i];
    vec3 *pic = (vec3*)output;
    vec3 col(0.f, 0.f, 0.f);
    for (int s = 0; s < ns; s++)
    {
        float dx = curand_uniform(&localState);
        float dy = curand_uniform(&localState);
        float u = float(x + dx) / float(nx); u = 2.f * u - 1.f;
        float v = float(y + dy) / float(ny); v = 2.f * v - 1.f;
        ray r(origin, u * horizonal + v * vertical + vec3{0.f, 0.f, -1.f});
        col += color(r);
    }
    states[i] = localState;
    col /= float(ns);
    pic[i] = col;
}

void save_curandState(void* output, int w, int h)
{
    char filename[128];
    sprintf_s(filename, 128, "curand_state_%dx%d.bin", w, h);
    FILE *f = fopen(filename, "wb");          
    fwrite(output,sizeof(curandState), w * h, f);
    fclose(f);
    fprintf(stdout, "- save curand states into %s\n", filename);
}

void load_curandState(void* output, int w, int h)
{
    char filename[128];
    sprintf_s(filename, 128, "curand_state_%dx%d.bin", w, h);
    FILE *f = fopen(filename, "wb");          
    fread(output,sizeof(curandState), w * h, f);
    fclose(f);
    fprintf(stdout, "- load curand states from %s\n", filename);
}

int TestSmallPTOnGPU(int width, int height, int samps)
{
    printf("\n Param  %d, %d, %d\n", width, height, samps);

    float* output_h = new float[width * height * 3]; // pointer to memory for image on the host (system RAM)
    float* output_d;    // pointer to memory for image on the device (GPU VRAM)

    std::chrono::duration<double> elapsed;

    int nSubx = (width + SUB_GRID_X - 1) / SUB_GRID_X;
    int nSuby = (width + SUB_GRID_Y - 1) / SUB_GRID_Y;

    dim3 block(BLOCK_X, BLOCK_Y, 1);   
    dim3 subgrid(SUB_GRID_X / block.x, SUB_GRID_Y / block.y, 1);
    dim3 grid( width / block.x, height / block.y, 1);


    CUDA_CALL_CHECK( cudaMalloc(&output_d, width * height * sizeof(float) * 3) );
        
    curandState *devStates;
    curandState *devStates_h = new curandState[width * height ];
    CUDA_CALL_CHECK(cudaMalloc((void **)&devStates, width * height * sizeof(curandState)));

    char curandState_filename[128];
    sprintf_s(curandState_filename, 128, "curand_state_%dx%d.bin", width, height);
    if (!file_exists(curandState_filename))
    {
        // Record start time                          
        auto startRand = std::chrono::high_resolution_clock::now();

        for (int i = 0; i < nSuby; ++i)
        {
            fprintf(stdout, "\rGenerate curand state(%5.2lf%%)...\n", 100.f * float(i) / float(nSuby));
            for (int j = 0; j < nSubx; ++j)
            {
                setup_random_kernel <<< subgrid, block >>>(devStates, width, height, j, i); 
                CUDA_CALL_CHECK(cudaGetLastError());
                CUDA_CALL_CHECK(cudaDeviceSynchronize());
            }
        }
        auto finishRand = std::chrono::high_resolution_clock::now();
        elapsed = finishRand - startRand;
        printf("Random State Done! Time=%lf seconds\n", elapsed.count());

        CUDA_CALL_CHECK(cudaMemcpy(devStates_h , devStates, width * height * sizeof(curandState), cudaMemcpyDeviceToHost));
        save_curandState(devStates_h, width, height);
    }
    else
    {
        load_curandState(devStates_h, width, height);
        CUDA_CALL_CHECK(cudaMemcpy(devStates, devStates_h , width * height * sizeof(curandState), cudaMemcpyHostToDevice));
    }


    printf("\nStart rendering... %d, %d, %d\n", width, height, samps);
 
    // Record start time                          
    auto start = std::chrono::high_resolution_clock::now();

#if 1
    for (int i = 0; i < nSubx; ++i)
        for (int j = 0; j < nSuby; ++j)
        {
            printf("Launch subgrid [%d, %d] \n", i, j);
            render_kernel <<< subgrid, block >>>(devStates, output_d, width, height, samps, i, j);  
        }
#else
    printf("Launch grid \n");
    render_kernel <<< grid, block >>>(devStates, output_d, width, height, samps);  
#endif

    CUDA_CALL_CHECK(cudaGetLastError());
    CUDA_CALL_CHECK(cudaDeviceSynchronize());

    // Record end time
    auto finish = std::chrono::high_resolution_clock::now();
    elapsed = finish - start;
    printf("Render Done! Time=%lf seconds\n", elapsed.count());

    CUDA_CALL_CHECK(cudaMemcpy(output_h, output_d, width * height * sizeof(float3), cudaMemcpyDeviceToHost));
    CUDA_CALL_CHECK( cudaFree(output_d) );  

    SaveToPPM(output_h, width, height);

    printf("Saved image to 'smallptcuda.ppm'\n");
    delete[] output_h;
    return 0;
}

int main(int argc, char *argv[])
{
    int width = 1280, height = 720, samps = 1024;
    //int width = 1024, height = 1024, samps = 256;
    
    if (argc > 1)
    {
        if (checkCmdLineFlag(argc, (const char **)argv, "width"))
            width = getCmdLineArgumentInt(argc, (const char **)argv, "width");
        if (checkCmdLineFlag(argc, (const char **)argv, "height"))
            height = getCmdLineArgumentInt(argc, (const char **)argv, "height");
        if (checkCmdLineFlag(argc, (const char **)argv, "samples"))
            samps = getCmdLineArgumentInt(argc, (const char **)argv, "samples");
    }
    CUDA_CALL_CHECK( cudaSetDevice(0) );

    TestSmallPTOnGPU(width, height, samps);
    system("PAUSE");
}
