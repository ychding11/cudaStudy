#include <iostream>
#include <ctime>
#include <chrono>
#include "float.h"
#include "utils.h"
#include "ray.h"
#include "hitable.h"
#include "material.h"
#include "hitable_list.h"
#include "sphere.h"

#if 0
float hit_sphere(const ray& r, const vec3& center, float radius)
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

vec3 color(const ray& r, hitable *world)
{
    hit_record rec;
    if (world->hit(r, 0.f, MAXFLOAT, rec))
    { 
        vec3 target = rec.p + rec.normal + random_in_unit_sphere();
        return 0.5 * color(ray(rec.p, target-rec.p), world);
    }
    else
    {
        vec3 unit_direction = unit_vector(r.direction());
        float t = 0.5*(unit_direction.y() + 1.0);
        return (1.0-t)*vec3(1.0, 1.0, 1.0) + t*vec3(0.5, 0.7, 1.0);
    }
}
#endif

vec3 color(const ray& r, hitable *world, int depth)
{
    hit_record rec;
    if (world->hit(r, 0.001f, MAXFLOAT, rec))
    { 
        ray scattered;
        vec3 attenuation;
        if (depth < 20 && rec.mat_ptr && rec.mat_ptr->scatter(r, rec, attenuation, scattered))
        {
            return attenuation * color(scattered, world, depth + 1);
        }
        else
        {
            return vec3(0.f, 0.f, 0.f);
        }
    }
    else
    {
        vec3 unit_direction = unit_vector(r.direction());
        float t = 0.5*(unit_direction.y() + 1.0);
        return (1.0-t)*vec3(1.0, 1.0, 1.0) + t*vec3(0.5, 0.7, 1.0);
    }
}

inline float clamp(float x) { return x < 0.0f ? 0.0f : x > 1.0f ? 1.0f : x; }

inline int  to_int(float x) { return int(pow(clamp(x), 1 / 2.2) * 255 + .5); }

void save_to_ppm(vec3* output, int w, int h, int s, int t)
{
    char filename[128];
    sprintf_s(filename, 128, "image-%d-%d-%d-%d.ppm", w, h, s, t);
    FILE *f = nullptr;
    fopen_s(&f, filename, "w");
    fprintf(f, "P3\n%d %d\n%d\n", w, h, 255);
    for (int i = 0; i < w * h; i++) 
        fprintf(f, "%d %d %d ", to_int(output[i].x()), to_int(output[i].y()), to_int(output[i].z()));
    fclose(f);

    fprintf(stdout, "- Save as %s\n\n", filename);
    char display_image[128];
    sprintf_s(display_image, 128, "ffplay.exe %s", filename);
    system(display_image);
}

int main()
{
    int nx = 256;
    int ny = 256;
    int ns = 32;

    srand48(time(NULL));

    vec3* pic = new vec3[nx * ny];

    vec3 low_left_corner(-1.f, -1.f, -1.f);
    vec3 horizonal(2.f, 0.f, 0.f);
    vec3 vertical(0.f, 2.f, 0.f);
    vec3 origin(0.f, 0.f, 0.f);

    hitable *list[4];
    list[0] = new sphere(vec3(0.f, 0.f, -1.f), 0.5f, new lambertian(vec3(0.8, 0.3, 0.3)));
    list[1] = new sphere(vec3(0.f, -100.5f, -1.f), 100.f, new lambertian(vec3(0.4, 0.8, 0.3)));
    list[2] = new sphere(vec3(1.f, 0.f, -1.f), 0.5f, new lambertian(vec3(0.8, 0.6, 0.2)));
    list[3] = new sphere(vec3(-1.f,0.f, 1.f), 100.f, new lambertian(vec3(0.8, 0.8, 0.8)));
    hitable* world = new hitable_list(list, 2);

    std::cout << "- Start Rendering... " << nx << " x " << ny << "\n";

    // Record start time                          
    auto start = std::chrono::high_resolution_clock::now();

    //#pragma omp parallel for schedule(dynamic, 1) private(col)
    for (int k = 0, j = ny-1; j >= 0; j--)
    {
        fprintf(stdout, "\rRendering (%d spp) %5.2f%%", ns, 100.*k/(nx * ny));        
        for (int i = 0; i < nx; i++)
        {
            vec3 col(0, 0, 0);
            for (int s=0; s < ns; s++)
            {
                float u = float(i + drand48()) / float(nx);
                float v = float(j + drand48()) / float(ny);
                ray r(origin, low_left_corner + u * horizonal + v * vertical);
                col += color(r, world, 0);
            }
            col /= float(ns);
            pic[k++] = col;
        }
    }
    // Record end time
    auto finish = std::chrono::high_resolution_clock::now();
    std::chrono::duration<double> elapsed = finish - start;
    printf("\n- Render Done! Time=%lf seconds\n", elapsed.count());
    save_to_ppm(pic, nx, ny, ns, int(elapsed.count()));
    delete[] pic;
    system("pause");
}
                     


