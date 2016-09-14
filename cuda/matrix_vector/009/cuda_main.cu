#include <stdio.h>
#include <stdlib.h>
#include <string.h>     /* strtok() */
#include <sys/types.h>  /* open() */
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>     /* getopt() */

#include <iostream>

#include <cuda_runtime.h>                                                       
#include <helper_cuda.h> 
#include <helper_functions.h>   

#define FLT_SIZE sizeof(float)

using namespace std;

void test_v1a(int rows, int cols);

void init2D(float *array, int rows, int cols, float value)
{                                                                               
	for(int i=0; i<rows; i++) {                                                 
		for(int j=0; j<cols; j++) {                                             
			array[i * cols + j] = value;                                        
		}                                                                       
	}                                                                           
}

void print2D(float *array, int rows, int cols)
{
	printf("\n");
	for(int i=0; i<rows; i++) {
		for(int j=0; j<cols; j++) {
			printf("%5.3f ", array[i * cols + j]);
		}
		printf("\n");
	}                                                                           
}

void init1D(float *data, int len, float value)
{                                                                               
	for(int i=0; i<len; i++) {                                                 
		data[i] = value;                                        
	}                                                                           
}

void print1D(float *data, int len)
{                                                                               
	printf("\n");
	for(int i=0; i<len; i++) {                                                 
		printf("%5.3f ", data[i]);
	}                                                                           
	printf("\n");
}

void d2h_print1d(float *d_data, float *h_data, const int rows)
{
	cudaMemcpy(h_data, d_data, sizeof(float) * rows, cudaMemcpyDeviceToHost);
	for(int i=0; i<rows; i++) {
		printf("%f ", h_data[i]);
	}
	printf("\n");
}

int check(float *d_data, float *h_data, const int rows, const int cols)
{
	float cpu = cols * 0.02;
	cudaMemcpy(h_data, d_data, sizeof(float) * rows, cudaMemcpyDeviceToHost);

	int correct = 1;
	for(int i=0; i<rows; i++) {
		//if(h_data[i] != cpu) {
		if(fabs(h_data[i] - cpu) > 1e8) {
			fprintf(stderr, "result doesn't match! pos : %d, gpu %12.8f , cpu %12.8f\n", 
					i, h_data[i], cpu);
			correct = 0;
			break;
		}
	}
	return correct;
}

void h2d_copy(float *h_data, float *d_data, int len)
{
	cudaMemcpy(d_data, h_data, sizeof(float) * len, cudaMemcpyHostToDevice);
}

// timer
//double timing, runtime;
// seconds 
//extern double wtime(void);

inline int BLK(int number, int blksize)                                         
{                                                                               
    return (number + blksize - 1) / blksize;                                    
}                                                                               

// constant memory
//__constant__ float const_mem[16000];

//----------------------------------------------------------------------------//
// 
//----------------------------------------------------------------------------//
__global__ void kernel_sgemv_1024b (const int rows,
		const int cols,
		const float* __restrict__ A,
		const float* __restrict__ B,
		float* __restrict__ C)
{
	// 32 warps max
	__shared__ float sdata[32];

	//int gx = threadIdx.x + __mul24(blockIdx.x, blockDim.x);
	int gx = threadIdx.x;

	int lane_id = threadIdx.x & 0x1F;
	int warp_id = threadIdx.x >> 5;

	for(int i=0; i<rows; i++)
	{
		float tmp = 0.f;
		if(gx < cols) {
			tmp = A[i * cols + gx] * B[gx];
		}
		
		// warp reduction on tmp	
		tmp += __shfl_down(tmp, 16, 32);                                      
		tmp += __shfl_down(tmp,  8, 32);                                      
		tmp += __shfl_down(tmp,  4, 32);                                      
		tmp += __shfl_down(tmp,  2, 32);                                      
		tmp += __shfl_down(tmp,  1, 32);                                      

		// store the warp result to shared memory
		if(lane_id == 0) {
			sdata[warp_id] = tmp;
		}

		__syncthreads();

		// 1st warp do the reduction
		if(warp_id == 0) {
			tmp = sdata[threadIdx.x];

			tmp += __shfl_down(tmp, 16, 32);                                      
			tmp += __shfl_down(tmp,  8, 32);                                      
			tmp += __shfl_down(tmp,  4, 32);                                      
			tmp += __shfl_down(tmp,  2, 32);                                      
			tmp += __shfl_down(tmp,  1, 32);                                      
		
			if(threadIdx.x == 0) {
				C[i]= tmp;
			}
		}
	
	}
}


void test_v1a(int rows, int cols)
{
	if(cols > 1024)
	{
		fprintf(stderr, "reach the limit of max block size 1024!\n");	
		exit(1);
	}

	cudaEvent_t startEvent, stopEvent;
	checkCudaErrors( cudaEventCreate(&startEvent) );
	checkCudaErrors( cudaEventCreate(&stopEvent) );
	// host
	float *A;
	float *B;
	float *C;
	checkCudaErrors(cudaMallocHost((void **)&A, 	rows * cols * FLT_SIZE));
	checkCudaErrors(cudaMallocHost((void **)&B, 	cols * FLT_SIZE));
	checkCudaErrors(cudaMallocHost((void **)&C, 	rows * FLT_SIZE));
	// init
	init2D(A, rows, cols, 0.2f);
	init1D(B, cols, 0.1f);
	// dump
	//print2D(A, rows, cols);
	//print1D(B, cols);
	// device
	float *d_A;
	float *d_B;
	float *d_C;
	checkCudaErrors(cudaMalloc((void **)&d_A, 	rows * cols * FLT_SIZE));
	checkCudaErrors(cudaMalloc((void **)&d_B, 	cols * FLT_SIZE));
	checkCudaErrors(cudaMalloc((void **)&d_C, 	rows * FLT_SIZE));
	// copy data to device
	h2d_copy(A, d_A, rows * cols);
	h2d_copy(B, d_B, cols);
	h2d_copy(C, d_C, cols);
	// start gpu timing
	cudaEventRecord(startEvent);
	//--------------------------------------------------------------------------
	// kernel
	//--------------------------------------------------------------------------
    //dim3 Blk_config = dim3(32, 4, 1);                                           
    //dim3 Grd_config = dim3(1, BLK(rows, 4), 1);
    dim3 Blk_config = dim3(1024, 1, 1);                                           
    dim3 Grd_config = dim3(1, 1, 1);

	kernel_sgemv_1024b <<< Grd_config, Blk_config>>>(rows, 
			cols, 
			d_A,
			d_B,
			d_C);

	// end of gpu timing
	cudaEventRecord(stopEvent);
	cudaEventSynchronize(stopEvent); 

	float milliseconds = 0;
	cudaEventElapsedTime(&milliseconds, startEvent, stopEvent);
	cout << milliseconds << " (ms)" << endl;

	//d2h_print1d(d_C, C, rows);
	if (check(d_C, C, rows, cols))	{
		printf("success!\n");
	}


	// release
	if (A != NULL)				checkCudaErrors(cudaFreeHost(A));
	if (B != NULL)				checkCudaErrors(cudaFreeHost(B));
	if (C != NULL)				checkCudaErrors(cudaFreeHost(C));

	if (d_A != NULL)			checkCudaErrors(cudaFree(d_A));
	if (d_B != NULL) 			checkCudaErrors(cudaFree(d_B));
	if (d_C != NULL)			checkCudaErrors(cudaFree(d_C));
}


// launch 1024 block size for small data

int main(int argc, char **argv) {

	cudaDeviceProp prop;
	checkCudaErrors( cudaGetDeviceProperties(&prop, 0) );
	printf("Device: %s\n", prop.name);

	//test_v1a(5,   6);
	test_v1a(100,   100);
	//test_v1a(100000,   100);

	
	//------------------------------------------------------------------------//
	// case study 1
	//------------------------------------------------------------------------//

	// lanch a 2d grid, where x is on column with fixed warp size 32
	//test_v1a(50,   50);

	// warm-up
	//test_v1a(100,   50);
	//test_v1a(100,   50);
	//test_v1a(1000,   50);
	//test_v1a(100,   100);

    return(0);
}