// MGBench: Multi-GPU Computing Benchmark Suite
// Copyright (c) 2016, Tal Ben-Nun
// Code adapted from MAPS - Memory Access Pattern Specification Framework
// http://maps-gpu.github.io/
// Copyright (c) 2015, A. Barak
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// * Redistributions of source code must retain the above copyright notice,
//   this list of conditions and the following disclaimer.
// * Redistributions in binary form must reproduce the above copyright notice,
//   this list of conditions and the following disclaimer in the documentation
//   and/or other materials provided with the distribution.
// * Neither the names of the copyright holders nor the names of its
//   contributors may be used to endorse or promote products derived from this
//   software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <ctime>
#include <chrono>

#include <vector>
#include <map>
#include <memory>

#include <gflags/gflags.h>

#include <cuda_runtime.h>
#include <device_launch_parameters.h>
#include <cublasXt.h>
#include <cublas_v2.h>


#include <maps/maps.cuh>
#include <maps/multi/multi.cuh>

//DEFINE_int32(m, 4100, "Matrix A height");
//DEFINE_int32(n, 4100, "Matrix A width (B height)");
//DEFINE_int32(k, 4100, "Matrix B width");
int m,n,k = 1000;
DEFINE_double(alpha, 1.0, "GEMM Alpha");
DEFINE_bool(double, false, "Use double-precision matrices");

DEFINE_bool(multithreading, true, "Run a thread per device");
DEFINE_bool(regression, true, "Perform regression tests");
DEFINE_bool(print_diffs, false, "Print each difference");
DEFINE_int32(random_seed, -1, "Override random seed (default is current time)");
unsigned int curtime = (unsigned int)time(NULL);

DEFINE_int32(repetitions, 10, "Number of repetitions for test");
DEFINE_uint64(heat, 0, "Run for a specified amount of seconds instead of "
              "repetitions");

DEFINE_int32(gpuoffset, 0, "Offset the first used GPU ID");
DEFINE_bool(scaling, false, "Scaling test mode");

#define CUBLAS_CHECK(expr) do {                                                    \
    cublasStatus_t status;                                                        \
    status = (expr);                                                            \
    if (status != CUBLAS_STATUS_SUCCESS)                                        \
    {                                                                            \
        printf("%s:%d: CUBLAS failed (%d)\n", __FILE__, __LINE__, (int)status);    \
        return false;                                                            \
    }                                                                            \
} while(0)

// Taken from CUDA samples
/* Host implementation of a simple version of sgemm */
template <typename T>
static void simple_gemm(int m, int n, int k, T alpha, const T *A, const T *B,
                         T beta, T *C)
{
    int i;
    int j;
    int l;

    for (i = 0; i < m; ++i)
    {
        for (j = 0; j < k; ++j)
        {
            T prod = 0;

            for (l = 0; l < n; ++l)
            {
                prod += A[l * m + i] * B[j * n + l];
            }

            C[j * m + i] = alpha * prod + beta * C[j * m + i];
        }
    }
}


struct GEMMContext
{
    std::vector<cublasHandle_t> handles;
};

template <typename T>
bool GEMMRoutine(void *context, int deviceIdx, cudaStream_t stream,
                  const maps::multi::GridSegment& task_segment,
                  const std::vector<void *>& parameters,
                  const std::vector<maps::multi::DatumSegment>& container_segments,
                  const std::vector<maps::multi::DatumSegment>& container_allocation);

template <>
bool GEMMRoutine<float>(void *context, int deviceIdx, cudaStream_t stream,
                        const maps::multi::GridSegment& task_segment,
                        const std::vector<void *>& parameters,
                        const std::vector<maps::multi::DatumSegment>& container_segments,
                        const std::vector<maps::multi::DatumSegment>& container_allocation)
{
    GEMMContext *c = (GEMMContext *)context;
    if (!c)
        return false;

    int m, n, k;
    float alpha, beta;
    maps::multi::GetConstantParameter(parameters[3], alpha);
    maps::multi::GetConstantParameter(parameters[4], beta);
    
    m = container_segments[0].m_dimensions[0];
    n = container_segments[1].m_dimensions[0];
    k = container_segments[2].m_dimensions[1];

    CUBLAS_CHECK(cublasSetStream(c->handles[deviceIdx], stream));
    CUBLAS_CHECK(cublasSgemm(c->handles[deviceIdx], CUBLAS_OP_N, CUBLAS_OP_N, m, k, n, &alpha, 
                 (float *)parameters[0], 
                 container_segments[0].m_stride_bytes / sizeof(float), 
                 (float *)parameters[1], 
                 container_segments[1].m_stride_bytes / sizeof(float), &beta, 
                 (float *)parameters[2],
                 container_segments[2].m_stride_bytes / sizeof(float)));

    return true;
}

template <>
bool GEMMRoutine<double>(void *context, int deviceIdx, cudaStream_t stream,
                        const maps::multi::GridSegment& task_segment,
                        const std::vector<void *>& parameters,
                        const std::vector<maps::multi::DatumSegment>& container_segments,
                        const std::vector<maps::multi::DatumSegment>& container_allocation)
{
    GEMMContext *c = (GEMMContext *)context;
    if (!c)
        return false;

    int m, n, k;
    double alpha, beta;
    maps::multi::GetConstantParameter(parameters[3], alpha);
    maps::multi::GetConstantParameter(parameters[4], beta);
    
    m = container_segments[0].m_dimensions[0];
    n = container_segments[1].m_dimensions[0];
    k = container_segments[2].m_dimensions[1];

    CUBLAS_CHECK(cublasSetStream(c->handles[deviceIdx], stream));
    CUBLAS_CHECK(cublasDgemm(c->handles[deviceIdx], CUBLAS_OP_N, CUBLAS_OP_N, m, k, n, &alpha, 
                 (double *)parameters[0],
                 container_segments[0].m_stride_bytes / sizeof(double),
                 (double *)parameters[1],
                 container_segments[1].m_stride_bytes / sizeof(double), &beta,
                 (double *)parameters[2],
                 container_segments[2].m_stride_bytes / sizeof(double)));

    return true;
}

template <typename T>
bool RunGEMM(int ngpus)
{ int loop=0; for (loop=1000;loop<=20000; loop+=500) {
    T alpha = (T)FLAGS_alpha, beta = T(0);
   
    size_t m = loop, n = loop, k = loop;
    //printf(" SIZE %d\n", loop);
    
    srand((FLAGS_random_seed < 0) ? curtime : FLAGS_random_seed);

    std::vector<T> hostA(m * n), hostB(n * k), Cres(m * k);

    // Generate input data
    for (size_t i = 0; i < m * n; ++i)
        hostA[i] = (T)rand() / (T)RAND_MAX;
    for (size_t i = 0; i < n * k; ++i)
        hostB[i] = (T)rand() / (T)RAND_MAX;

    // Create GPU list
    int num_gpus;
    MAPS_CUDA_CHECK(cudaGetDeviceCount(&num_gpus));
    std::vector<unsigned int> gpuids;
    for (int i = 0; i < ngpus; ++i)
        gpuids.push_back((i + FLAGS_gpuoffset) % num_gpus);

    // Create CUBLAS handles
    GEMMContext context;
    for (int k = 0; k < ngpus; ++k)
    {
        MAPS_CUDA_CHECK(cudaSetDevice(gpuids[k]));

        cublasHandle_t handle;
        CUBLAS_CHECK(cublasCreate(&handle));
        context.handles.push_back(handle);
    }
    
    // Create scheduler
    maps::multi::Scheduler sched (gpuids);

    if (!FLAGS_multithreading) {
        sched.DisableMultiThreading();
    }

    // Define data structures to be used
    maps::multi::Matrix<T> A (m, n), B (n, k), C (m, k);

    A.Bind(&hostA[0]);
    B.Bind(&hostB[0]);

    // Analyze the memory access patterns for allocation purposes
    if (!FLAGS_scaling)
    {
        maps::multi::AnalyzeCall(sched, dim3(), dim3(), 
            maps::multi::Block2DUnmodified<true, T>(A),
            maps::multi::Block2DUnmodified<false, T>(B),
            maps::multi::StructuredInjectiveMatrixO<T>(C));
    }
    else
    {
        maps::multi::AnalyzeCallAll(sched, dim3(), dim3(), 
            maps::multi::Block2DUnmodified<true, T>(A),
            maps::multi::Block2DUnmodified<false, T>(B),
            maps::multi::StructuredInjectiveMatrixO<T>(C));

    }
    
    for (int i = 0; i < num_gpus; i++)
    {
        MAPS_CUDA_CHECK(cudaSetDevice(i));
        MAPS_CUDA_CHECK(cudaDeviceSynchronize());
    }
    MAPS_CUDA_CHECK(cudaSetDevice(0));    
    auto t1 = std::chrono::high_resolution_clock::now();
    auto t2 = std::chrono::high_resolution_clock::now();

    do
    {
        if (!FLAGS_scaling)
        {    
            // Invoke the kernels
            for (int i = 0; i < FLAGS_repetitions; ++i)
            {
                sched.InvokeUnmodified(GEMMRoutine<T>, &context, dim3(),
                                       maps::multi::Block2DUnmodified<true, T>(A),
                                       maps::multi::Block2DUnmodified<false, T>(B),
                                       maps::multi::StructuredInjectiveMatrixO<T>(C),
                                       alpha, beta);
            }
        }
        else
        {
            // Invoke the kernels
            for (int i = 0; i < FLAGS_repetitions; ++i)
            {
                sched.InvokeAllUnmodified(GEMMRoutine<T>, &context, dim3(),
                                          maps::multi::Block2DUnmodified<true, T>(A),
                                          maps::multi::Block2DUnmodified<false, T>(B),
                                          maps::multi::StructuredInjectiveMatrixO<T>(C),
                                          alpha, beta);
            }        
        }
        
        sched.WaitAll();
        for (int i = 0; i < num_gpus; i++)
        {
            MAPS_CUDA_CHECK(cudaSetDevice(i));
            MAPS_CUDA_CHECK(cudaDeviceSynchronize());
        }
        t2 = std::chrono::high_resolution_clock::now();
        
    } while ((FLAGS_heat > 0) &&
             (std::chrono::duration_cast<std::chrono::seconds>(t2 - t1).count() < FLAGS_heat));

    if (FLAGS_heat == 0)
    {
        printf("%d %f \n", m,
               std::chrono::duration_cast<std::chrono::microseconds>(t2 - t1).count() / 1000.0f / FLAGS_repetitions);
    }
    else
    {
        printf("%sGEMM successfully ran for %f seconds\n", (sizeof(T) == sizeof(float) ? "S" : "D"),
               std::chrono::duration_cast<std::chrono::microseconds>(t2 - t1).count() * 1e-6);
    }
       
    bool result = true;

    // Regression
  /*  if (!FLAGS_scaling && FLAGS_regression)
    {
        T meanDiff = 0.0f;
        int numDiffs = 0;

        // Gather back to host
        C.Bind(&Cres[0]);
        maps::multi::Gather(sched, C);
        
        std::vector<T> hostC(m * k, 0);
        // Here i will send different matrix sizes.
        
        simple_gemm<T>(m, n, k, alpha, &hostA[0], &hostB[0], beta, &hostC[0]);

        for (size_t i = 0; i < m * k; ++i)
        {
            T diff = fabs(1.0f - (Cres[i] / hostC[i]));
            if (diff > 1e-3)
            {
                if (FLAGS_print_diffs)
                    printf("Difference in index %d, %d: %f != %f\n", (int)(i / m), (int)(i % m), Cres[i], hostC[i]);
                numDiffs++;
            }
            meanDiff += diff;
        }
        meanDiff /= (m * k);

        printf("SUMMARY: %d/%d large differences, total mean normalized diff: %f\n", numDiffs, (int)(m*k), meanDiff);
        if (numDiffs > 0 || meanDiff > 1e-4)
            result = false;
    }

    printf("TEST %s\n\n", result ? "passed" : "FAILED");
*/
    // Destroy CUBLAS contexts
    for (int k = 0; k < ngpus; ++k)
    {
        MAPS_CUDA_CHECK(cudaSetDevice(gpuids[k]));
        CUBLAS_CHECK(cublasDestroy(context.handles[k]));
    }

    //return result;

}
}

bool TestMatMulMAPSMultiUnmodified(int ngpus) 
{
    if (FLAGS_double)
        return RunGEMM<double>(ngpus);
    else
        return RunGEMM<float>(ngpus);
}
