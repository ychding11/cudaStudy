// based on smallpt, a path tracer by Kevin Beason, 2008  
 
#include <iostream>
#include <chrono>  // for high_resolution_clock
#include <cuda_runtime.h>
#include <vector_types.h>
#include "device_launch_parameters.h"
#include "cutil_math.h" // from http://www.icmc.usp.br/~castelo/CUDA/common/inc/cutil_math.h
#include "helper_string.h"


#define CUDA_CALL_CHECK(x)                             \
do{                                                    \
    if((x) != cudaSuccess)                             \
    {                                                  \
        cudaError_t cudaStatus = x;                    \
        printf("Error at %s:%d\t",__FILE__,__LINE__);  \
        printf("%s %d\t",#x, (cudaStatus));            \
        printf("%s\n",cudaGetErrorString(cudaStatus)); \
        system("pause");                               \
        return EXIT_FAILURE;                           \
    }                                                  \
} while(0)


#define M_PI 3.14159265359f  // pi

// __device__ : executed on the device (GPU) and callable only from the device
struct Ray
{ 
 float3 orig; // ray origin
 float3 dir;  // ray direction 
 __device__ Ray(float3 o_, float3 d_) : orig(o_), dir(d_) {} 
};

enum Refl_t { DIFF, SPEC, REFR };  // material types, used in radiance(), only DIFF used here

//< use on GPU
 __constant__ float epsilon = 1e-6f;  // epsilon required to prevent floating point precision artifacts

struct Sphere
{
 float rad;            // radius 
 float3 pos, emi, col; // position, emission, colour 
 Refl_t refl;          // reflection type (e.g. diffuse)

__device__ float intersect_sphere(const Ray &r) const 
{ 
 // ray/sphere intersection
 // returns distance t to intersection point, 0 if no hit  
 // ray equation: p(x,y,z) = ray.orig + t*ray.dir
 // general sphere equation: x^2 + y^2 + z^2 = rad^2 
 // classic quadratic equation of form ax^2 + bx + c = 0 
 // solution x = (-b +- sqrt(b*b - 4ac)) / 2a
 // solve t^2*ray.dir*ray.dir + 2*t*(orig-p)*ray.dir + (orig-p)*(orig-p) - rad*rad = 0 
 // more details in "Realistic Ray Tracing" book by P. Shirley or Scratchapixel.com

  float3 op = pos - r.orig;    // distance from ray.orig to center sphere 
  float t;
  float b = dot(op, r.dir);    // b in quadratic equation
  float disc = b*b - dot(op, op) + rad*rad;  // discriminant quadratic equation
  if (disc<0) return 0;       // if disc < 0, no real solution (we're not interested in complex roots) 
  else disc = sqrtf(disc);    // if disc >= 0, check for solutions using negative and positive discriminant
  return (t = b - disc)>epsilon ? t : ((t = b + disc)>epsilon ? t : 0); // pick closest point in front of ray origin
}

};

// SCENE
// 9 spheres forming a Cornell box
// small enough to be in constant GPU memory
// { float radius, { float3 position }, { float3 emission }, { float3 colour }, refl_type }
__constant__ Sphere spheres[] =
{
 { 1e5f, { 1e5f + 1.0f, 40.8f, 81.6f }, { 0.0f, 0.0f, 0.0f }, { 0.75f, 0.25f, 0.25f }, DIFF }, //Left 
 { 1e5f, { -1e5f + 99.0f, 40.8f, 81.6f }, { 0.0f, 0.0f, 0.0f }, { .25f, .25f, .75f }, DIFF }, //Rght 
 { 1e5f, { 50.0f, 40.8f, 1e5f }, { 0.0f, 0.0f, 0.0f }, { .75f, .75f, .75f }, DIFF }, //Back 
 { 1e5f, { 50.0f, 40.8f, -1e5f + 600.0f }, { 0.0f, 0.0f, 0.0f }, { 1.00f, 1.00f, 1.00f }, DIFF }, //Frnt 
 { 1e5f, { 50.0f, 1e5f, 81.6f }, { 0.0f, 0.0f, 0.0f }, { .75f, .75f, .75f }, DIFF }, //Botm 
 { 1e5f, { 50.0f, -1e5f + 81.6f, 81.6f }, { 0.0f, 0.0f, 0.0f }, { .75f, .75f, .75f }, DIFF }, //Top 
 { 16.5f, { 27.0f, 16.5f, 47.0f }, { 0.0f, 0.0f, 0.0f }, { 1.0f, 1.0f, 1.0f }, DIFF }, // small sphere 1
 { 16.5f, { 73.0f, 16.5f, 78.0f }, { 0.0f, 0.0f, 0.0f }, { 1.0f, 1.0f, 1.0f }, DIFF }, // small sphere 2
 { 600.0f, { 50.0f, 681.6f - .77f, 81.6f }, { 2.0f, 1.8f, 1.6f }, { 0.0f, 0.0f, 0.0f }, DIFF }  // Light
};

// param t is distance to closest intersection, initialise t to a huge number outside scene
// param i is the intersected sphere id.
__device__ inline bool intersect_scene(const Ray &r, float &t, int &id)
{
 float n = sizeof(spheres) / sizeof(Sphere), d, inf = t = 1e20;  
 for (int i = int(n); i--;)  // test all scene objects for intersection
  if ((d = spheres[i].intersect_sphere(r)) && d<t) // if newly computed intersection distance d is smaller than current closest intersection distance
  {  
    t = d;  // keep track of distance along ray to closest intersection point 
    id = i; // and closest intersected object
  }
 return t < inf; // returns true if an intersection with the scene occurred, false when no hit
}

// random number generator from https://github.com/gz/rust-raytracer
__device__ static float getrandom(unsigned int *seed0, unsigned int *seed1)
{
 *seed0 = 36969 * ((*seed0) & 65535) + ((*seed0) >> 16);  // hash the seeds using bitwise AND and bitshifts
 *seed1 = 18000 * ((*seed1) & 65535) + ((*seed1) >> 16);

 unsigned int ires = ((*seed0) << 16) + (*seed1);

 // Convert to float
 union
 {
  float f;
  unsigned int ui;
 } res;
 res.ui = (ires & 0x007fffff) | 0x40000000;  // bitwise AND, bitwise OR

 return (res.f - 2.f) / 2.f;
}

// radiance function, the mean of path tracing 
// solves the rendering equation: 
// outgoing radiance (at a point) = emitted radiance + reflected radiance
// reflected radiance is sum (integral) of incoming radiance from all directions in hemisphere above point, 
// multiplied by reflectance function of material (BRDF) and cosine incident angle 
// returns radiance by ray 
__device__ float3 radiance(Ray &r, unsigned int *s1, unsigned int *s2)
{ 
 float3 accucolor = make_float3(0.0f, 0.0f, 0.0f); // accumulates ray colour with each iteration through bounce loop
 float3 mask = make_float3(1.0f, 1.0f, 1.0f); 

 // ray bounce loop (no Russian Roulette used) 
 // iteration up to 4 bounces (replaces recursion in CPU code)
 for (int bounces = 0; bounces < 4; bounces++)
 {  
  float t;           // distance to closest intersection 
  int id = 0;        // index of closest intersected sphere 

// test ray for intersection with scene
  if (!intersect_scene(r, t, id))
   return make_float3(0.0f, 0.0f, 0.0f); // if miss, return black

  const Sphere &obj = spheres[id];  // hitobject
  float3 x = r.orig + r.dir*t;          // hitpoint 
  float3 n = normalize(x - obj.pos);    // normal
  float3 nl = dot(n, r.dir) < 0 ? n : n * -1; // front facing normal

  // add emission of current sphere to accumulated colour(first term in rendering equation sum) 
  accucolor += mask * obj.emi;

  // all spheres in the scene are diffuse
  // generate new diffuse ray:
  // origin = hitpoint of previous ray in path
  // random direction in hemisphere above hitpoint (see "Realistic Ray Tracing", P. Shirley)

  // create 2 random numbers
  float r1 = 2 * M_PI * getrandom(s1, s2); // pick random number on unit circle (radius = 1, circumference = 2*Pi) for azimuth
  float r2 = getrandom(s1, s2);  // pick random number for elevation
  float r2s = sqrtf(r2); 

  // compute local orthonormal basis uvw at hitpoint for calculation random ray direction 
  // first vector = normal at hitpoint, second vector is orthogonal to first, third vector is orthogonal to first two vectors
  float3 w = nl; 
  float3 u = normalize(cross((fabs(w.x) > .1 ? make_float3(0, 1, 0) : make_float3(1, 0, 0)), w));  
  float3 v = cross(w,u);

  // cosine weighted importance sampling (favours ray directions closer to normal direction)
  float3 d = normalize(u * cos(r1) * r2s + v * sin(r1) * r2s + w * sqrtf(1 - r2));
  r.orig = x + nl * 0.05f; // offset ray origin slightly to prevent self intersection
  r.dir = d;

  mask *= obj.col;    // multiply with colour of object       
  mask *= dot(d,nl);  // weigh light contribution using cosine of angle between incident light and normal
  mask *= 2;          // fudge factor
 }

 return accucolor;
}

// __global__ : executed on the device (GPU) and called only from host (CPU) 
__global__ void render_kernel(float3 *output, int width, int height, int samps, float vfov = 45.f)
{
    // assign a CUDA thread to every pixel (x,y) 
    // blockIdx, blockDim and threadIdx are CUDA specific keywords
    // replaces nested outer loops in CPU code looping over image rows and image columns 
    unsigned int x = blockIdx.x*blockDim.x + threadIdx.x;
    unsigned int y = blockIdx.y*blockDim.y + threadIdx.y;

    //< index of current pixel in one Dimension 
    //< reverse y axis
    unsigned int i = (height - y - 1) * width + x;

    unsigned int s1 = x;  // seeds for random number generator
    unsigned int s2 = y;

    float3 r = make_float3(0.0f);

    // hardcoded camera ray(origin, direction) 
    Ray cam(make_float3(50, 52, 255.f), normalize(make_float3(0, -0.042612f, -1))); 

    float3 up = make_float3(0, 1, 0);
    //float vfov = 45.f;
    auto ratio = float(height) / float(width);
    auto dir = normalize(cam.dir);
    auto image_u = normalize(cross(dir, up));
    auto image_v = normalize(cross(image_u, dir));
    auto image_w = std::tan(vfov * float (M_PI * (1.f / 180.f) * 0.5f));
    image_u = image_u * image_w;
    image_v = image_v * image_w * ratio;

    //< AA : samples per pixel
    //< It is NOT progressive mode
    float u, v;
    float3 d;
    float invSamps = (1. / samps);
    for (int s = 0; s < (samps >> 2); s++)
	{  
        //< Performance goes down by applying AA. 1.1s --> 1.3s
        {
		    //< ray sampling from camera & collect radiance 
            u = (2 * (x + 0.25f)) / float(width)  - 1.0f ;
            v = (2 * (y + 0.25f)) / float(height) - 1.0f ;
            d = image_u * u + image_v * v + dir;
            r = r + radiance(Ray(cam.orig, normalize(d)), &s1, &s2) * invSamps;

            u = (2 * (x + 0.75f)) / float(width)  - 1.0f ;
            v = (2 * (y + 0.25f)) / float(height) - 1.0f ;
            d = image_u * u + image_v * v + dir;
            r = r + radiance(Ray(cam.orig, normalize(d)), &s1, &s2) * invSamps;

            u = (2 * (x + 0.25f)) / float(width)  - 1.0f ;
            v = (2 * (y + 0.75f)) / float(height) - 1.0f ;
            d = image_u * u + image_v * v + dir;
            r = r + radiance(Ray(cam.orig, normalize(d)), &s1, &s2) * invSamps;

            u = (2 * (x + 0.75f)) / float(width)  - 1.0f ;
            v = (2 * (y + 0.75f)) / float(height) - 1.0f ;
            d = image_u * u + image_v * v + dir;
            r = r + radiance(Ray(cam.orig, normalize(d)), &s1, &s2) * invSamps;
        }
    }

    //< write raw rgb value to buffer on the GPU 
    //< clamp & gamma is done on CPU
    output[i] = make_float3(r.x, r.y, r.z);
    //output[i] = make_float3(clamp(r.x, 0.0f, 1.0f), clamp(r.y, 0.0f, 1.0f), clamp(r.z, 0.0f, 1.0f));
}

//< clamp x into [0, 1]
inline float clamp(float x) { return x < 0.0f ? 0.0f : x > 1.0f ? 1.0f : x; } 

// convert RGB float  [0,1] ==> int [0, 255] and perform gamma correction
inline int toInt(float x){ return int(pow(clamp(x), 1 / 2.2) * 255 + .5); } 

void SaveToPPM(float3* output, int w, int h);

int TestSmallPTOnGPU(int width, int height, int samps, float vfov = 45.f)
{
    float3* output_h = new float3[width * height]; // pointer to memory for image on the host (system RAM)
    float3* output_d;    // pointer to memory for image on the device (GPU VRAM)

    CUDA_CALL_CHECK( cudaSetDevice(0) );

    // allocate memory on the CUDA device (GPU VRAM)
    CUDA_CALL_CHECK( cudaMalloc(&output_d, width * height * sizeof(float3)) );
        
    dim3 block(8, 8, 1);   
    dim3 grid(width / block.x, height / block.y, 1);

    printf("\nStart rendering... %d, %d, %d, %f\n", width, height, samps, vfov);
 
    // Record start time                          
    auto start = std::chrono::high_resolution_clock::now();

    //< schedule threads on device and launch CUDA kernel from host
    //< use default stream
    render_kernel <<< grid, block >>>(output_d, width, height, samps, vfov);  
    CUDA_CALL_CHECK(cudaDeviceSynchronize());

    // Check for any errors launching the kernel
    CUDA_CALL_CHECK(cudaGetLastError());

    // Record end time
    auto finish = std::chrono::high_resolution_clock::now();
    std::chrono::duration<double> elapsed = finish - start;
    //std::cout << "Elapsed time: " << elapsed.count() << " s\n";
    printf("Render Done! Time=%lf seconds\n", elapsed.count());

    // copy result from device back to host
    CUDA_CALL_CHECK(cudaMemcpy(output_h, output_d, width * height * sizeof(float3), cudaMemcpyDeviceToHost));
 
    // free CUDA memory
    CUDA_CALL_CHECK( cudaFree(output_d) );  

    SaveToPPM(output_h, width, height);

    printf("Saved image to 'smallptcuda.ppm'\n");
    delete[] output_h;
    return 0;
}

static void help(const char *name)
{
    printf("Usage:  %s [OPTION]...\n", name);
    printf("A simple path tracer by cuda. \n");
    printf("\n");

    printf("Options:\n");
    printf("--help\t\t Display this help menu, exit\n\n");
    printf("-width=value\t\t set width, int\n");
    printf("-height=value\t\t set height, int\n");
    printf("-samples=value\t\t set samples per pixel, int \n");
    printf("-vfov=value\t\t set vertical fov, float\n");

    exit(0);
}

int main(int argc, char *argv[])
{
    int width = 800, height = 800, samps = 800;
    float vfov = 45.f;
    bool showHelp = false;
    
    if (argc > 1)
    {
        if (checkCmdLineFlag(argc, (const char**)argv, "help"))
        {
            help(argv[0]);
        }
        if (checkCmdLineFlag(argc, (const char **)argv, "width"))
            width = getCmdLineArgumentInt(argc, (const char **)argv, "width");
        if (checkCmdLineFlag(argc, (const char **)argv, "height"))
            height = getCmdLineArgumentInt(argc, (const char **)argv, "height");
        if (checkCmdLineFlag(argc, (const char **)argv, "samples"))
            samps = getCmdLineArgumentInt(argc, (const char **)argv, "samples");
        if (checkCmdLineFlag(argc, (const char **)argv, "vfov"))
            vfov = getCmdLineArgumentFloat(argc, (const char **)argv, "vfov");
    }

    TestSmallPTOnGPU(width, height, samps, vfov);

    system("ffplay smallptcuda.ppm");
    system("PAUSE");
}

void SaveToPPM(float3* output, int w, int h)
{
    // Write image to PPM file, a very simple image file format
    FILE *f = fopen("smallptcuda.ppm", "w");          
    fprintf(f, "P3\n%d %d\n%d\n", w, h, 255);
    for (int i = 0; i < w * h; i++)  // loop over pixels, write RGB values
        fprintf(f, "%d %d %d ", toInt(output[i].x), toInt(output[i].y), toInt(output[i].z));
    fclose(f);
}