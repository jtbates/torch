
#define CUDA_MAX_THREADS 1024   // this is safe, in reality 256 is our limit

/*
 * Description:
 *    this function subsamples an input 3D tensor along dimensions 1 and 2
 *    3D input, 3D output, 1D weight, 1D bias
 */
__global__ void subsample(float *input, float *output, float *weight, float *bias,
                          int input_n, int input_h, int input_w,
                          int kH, int kW, int dH, int dW)
{
  // iterators
  int xx, yy;

  // output size
  int output_w = (input_w - kW) / dW + 1;
  int output_h = (input_h - kH) / dH + 1;

  // compute offsets based on thread/block ID
  int o = blockIdx.x;
  int i = o;
  int k = blockIdx.x % input_n;

  int xx_start = threadIdx.x;
  int xx_end = output_w;
  int xx_step = blockDim.x;

  int yy_start = blockDim.y*blockIdx.y + threadIdx.y;
  int yy_end = output_h;
  int yy_step = blockDim.y*gridDim.y;

  // select input/output plane
  output = output + o*output_w*output_h;
  input = input + i*input_w*input_h;

  // Get the good mask for (k,i) (k out, i in)
  float the_weight = weight[k];

  // Initialize to the bias
  float the_bias = bias[k];

  // For all output pixels...
  for(yy = yy_start; yy < yy_end; yy+=yy_step) {
    for(xx = xx_start; xx < xx_end; xx+=xx_step) {
      // Compute the mean of the input image...
      float *ptr_input = input + yy*dH*input_w + xx*dW;
      float *ptr_output = output + yy*output_w + xx;
      float sum = 0;
      int kx, ky;
      for(ky = 0; ky < kH; ky++) {
        for(kx = 0; kx < kW; kx++)
          sum += ptr_input[kx];
        ptr_input += input_w; // next input line
      }
      // Update output
      *ptr_output = the_weight*sum + the_bias;
    }
  }
}

/*
 * Description:
 *    this function computes the gradWeight from input and gradOutput
 */
__global__ void subgradweight(float *input, float *gradOutput, float *gradWeight, float *gradBias,
                              int input_n, int input_h, int input_w,
                              int kH, int kW, int dH, int dW,
                              float scale)
{
  // iterators
  int xx, yy;

  // output size
  int output_w = (input_w - kW) / dW + 1;
  int output_h = (input_h - kH) / dH + 1;

  // compute offsets based on thread/block ID
  int o = blockIdx.x;
  int i = o;
  int k = blockIdx.x % input_n;

  int xx_start = threadIdx.x;
  int xx_end = output_w;
  int xx_step = blockDim.x;

  int yy_start = threadIdx.y;
  int yy_end = output_h;
  int yy_step = blockDim.y;

  // select input/output plane
  gradOutput = gradOutput + o*output_w*output_h;
  input = input + i*input_w*input_h;

  // thread ID
  int tid = blockDim.x*threadIdx.y + threadIdx.x;

  // create array to hold partial sums
  __shared__ float sums[CUDA_MAX_THREADS];
  sums[tid] = 0;

  // compute partial sums
  for(yy = yy_start; yy < yy_end; yy+=yy_step) {
    for(xx = xx_start; xx < xx_end; xx+=xx_step) {
      float *ptr_input = input + yy*dH*input_w + xx*dW;
      float *ptr_gradOutput = gradOutput + yy*output_w + xx;
      float z = *ptr_gradOutput;
      long kx, ky;
      for(ky = 0; ky < kH; ky++) {
        for(kx = 0; kx < kW; kx++) {
          sums[tid] += z * ptr_input[kx];
        }
        ptr_input += input_w;
      }
    }
  }
  __syncthreads();

  // reduce: accumulate all partial sums to produce final gradWeight
  if ((threadIdx.x == 0) && (threadIdx.y == 0)) {
    for(int i = 0; i < blockDim.x*blockDim.y; i++) gradWeight[k] += scale*sums[i];
  }
  __syncthreads();

  // compute gradBias
  sums[tid] = 0;
  for (int i=tid; i<output_w*output_h; i+=(blockDim.x*blockDim.y)) {
    sums[tid] += gradOutput[i];
  }
  __syncthreads();

  // reduce gradBias
  if ((threadIdx.x == 0) && (threadIdx.y == 0)) { 
    for (int i=0; i<(blockDim.x*blockDim.y); i++)
      gradBias[k] += scale*sums[i];
  }
}

/*
 * Description:
 *    this function computes the gradInput from weight and gradOutput
 */
__global__ void subgradinput(float *gradInput, float *gradOutput, float *weight,
                             int input_n, int input_h, int input_w,
                             int kH, int kW, int dH, int dW)
{
  // iterators
  int xx, yy;

  // output size
  int output_w = (input_w - kW) / dW + 1;
  int output_h = (input_h - kH) / dH + 1;

  // compute offsets based on thread/block ID
  int o = blockIdx.x;
  int i = o;
  int k = blockIdx.x % input_n;

  int xx_start = threadIdx.x;
  int xx_end = output_w;
  int xx_step = blockDim.x;

  int yy_start = blockDim.y*blockIdx.y + threadIdx.y;
  int yy_end = output_h;
  int yy_step = blockDim.y*gridDim.y;

  // select input/output plane
  gradOutput = gradOutput + o*output_w*output_h;
  gradInput = gradInput + i*input_w*input_h;

  // get weight
  float the_weight = weight[k];

  // compute gradInput
  for(yy = yy_start; yy < yy_end; yy+=yy_step) {
    for(xx = xx_start; xx < xx_end; xx+=xx_step) {
      float *ptr_gradInput = gradInput + yy*dH*input_w + xx*dW;
      float *ptr_gradOutput = gradOutput + yy*output_w + xx;
      float z = *ptr_gradOutput * the_weight;
      int kx, ky;
      for(ky = 0; ky < kH; ky++) {
        for(kx = 0; kx < kW; kx++)
          ptr_gradInput[kx] += z;
        ptr_gradInput += input_w;
      }
    }
  }
}

static int cunn_SpatialSubSampling_updateOutput(lua_State *L)
{
  THCudaTensor *input = (THCudaTensor *)luaT_checkudata(L, 2, torch_CudaTensor_id);
  int kW = luaT_getfieldcheckint(L, 1, "kW");
  int kH = luaT_getfieldcheckint(L, 1, "kH");
  int dW = luaT_getfieldcheckint(L, 1, "dW");
  int dH = luaT_getfieldcheckint(L, 1, "dH");
  int nInputPlane = luaT_getfieldcheckint(L, 1, "nInputPlane");

  THCudaTensor *weight = (THCudaTensor *)luaT_getfieldcheckudata(L, 1, "weight", torch_CudaTensor_id);
  THCudaTensor *bias = (THCudaTensor *)luaT_getfieldcheckudata(L, 1, "bias", torch_CudaTensor_id);
  THCudaTensor *output = (THCudaTensor *)luaT_getfieldcheckudata(L, 1, "output", torch_CudaTensor_id);

  float *weight_data = THCudaTensor_data(weight);
  float *bias_data = THCudaTensor_data(bias);
  float *output_data;
  float *input_data;

  luaL_argcheck(L, input->nDimension == 3 || input->nDimension == 4, 2, "3D or 4D (batch) tensor expected");

  if (input->nDimension == 3) {
    long nInputCols = input->size[2];
    long nInputRows = input->size[1];
    long nOutputCols = (nInputCols - kW) / dW + 1;
    long nOutputRows = (nInputRows - kH) / dH + 1;

    luaL_argcheck(L, input->size[0] == nInputPlane, 2, "invalid number of input planes");
    luaL_argcheck(L, nInputCols >= kW && nInputRows >= kH, 2, "input image smaller than kernel size");

    input = THCudaTensor_newContiguous(input);
    input_data = THCudaTensor_data(input);

    THCudaTensor_resize3d(output, nInputPlane, nOutputRows, nOutputCols);
    output_data = THCudaTensor_data(output);

    // cuda blocks & threads:
    int yblocks = floor(16 / nInputPlane);
    yblocks = yblocks < 1 ? 1 : yblocks;
    dim3 blocks(nInputPlane,yblocks);
    dim3 threads(32,8);

    // sync
    cudaDeviceSynchronize();

    // run subsample kernel
    subsample <<<blocks, threads>>> (input_data, output_data, weight_data, bias_data,
                                     nInputPlane, nInputRows, nInputCols, kH, kW, dH, dW);
  } else {
    long nInputCols = input->size[3];
    long nInputRows = input->size[2];
    long nbatch = input->size[0];
    long nOutputCols = (nInputCols - kW) / dW + 1;
    long nOutputRows = (nInputRows - kH) / dH + 1;

    luaL_argcheck(L, input->size[1] == nInputPlane, 2, "invalid number of input planes");
    luaL_argcheck(L, nInputCols >= kW && nInputRows >= kH, 2, "input image smaller than kernel size");

    input = THCudaTensor_newContiguous(input);
    input_data = THCudaTensor_data(input);

    THCudaTensor_resize4d(output, nbatch, nInputPlane, nOutputRows, nOutputCols);
    output_data = THCudaTensor_data(output);

    // cuda blocks & threads:
    int yblocks = floor(16 / nInputPlane);
    yblocks = yblocks < 1 ? 1 : yblocks;
    dim3 blocks(nInputPlane*nbatch,yblocks);
    dim3 threads(32,8);

    // sync
    cudaDeviceSynchronize();

    // run subsample kernel
    subsample <<<blocks, threads>>> (input_data, output_data, weight_data, bias_data,
                                     nInputPlane, nInputRows, nInputCols, kH, kW, dH, dW);
  }

  // sync & clean
  cudaDeviceSynchronize();
  THCudaTensor_free(input);

  // check for errors
  cudaError_t err = cudaGetLastError();
  if (err != cudaSuccess) {
    printf("error in SpatialSubsampling.updateOutput: %s\n", cudaGetErrorString(err));
    THError("aborting");
  }
  return 1;
}

static int cunn_SpatialSubSampling_updateGradInput(lua_State *L)
{
  THCudaTensor *input = (THCudaTensor *)luaT_checkudata(L, 2, torch_CudaTensor_id);
  THCudaTensor *gradOutput = (THCudaTensor *)luaT_checkudata(L, 3, torch_CudaTensor_id);
  int kW = luaT_getfieldcheckint(L, 1, "kW");
  int kH = luaT_getfieldcheckint(L, 1, "kH");
  int dW = luaT_getfieldcheckint(L, 1, "dW");
  int dH = luaT_getfieldcheckint(L, 1, "dH");
  int nInputPlane = luaT_getfieldcheckint(L, 1, "nInputPlane");

  luaL_argcheck(L, dW == kW, 1, "dW and kW must be equal (this will be fixed soon)");
  luaL_argcheck(L, dH == kH, 1, "dH and kH must be equal (this will be fixed soon)");

  THCudaTensor *weight = (THCudaTensor *)luaT_getfieldcheckudata(L, 1, "weight", torch_CudaTensor_id);
  THCudaTensor *gradInput = (THCudaTensor *)luaT_getfieldcheckudata(L, 1, "gradInput", torch_CudaTensor_id);

  if (input->nDimension == 3) {
    long nInputCols = input->size[2];
    long nInputRows = input->size[1];

    float *weight_data = THCudaTensor_data(weight);
    float *gradOutput_data = THCudaTensor_data(gradOutput);
    float *gradInput_data;

    THCudaTensor_resizeAs(gradInput, input);
    THCudaTensor_zero(gradInput);
    gradInput_data = THCudaTensor_data(gradInput);

    // cuda blocks & threads:
    int yblocks = floor(16 / nInputPlane);
    yblocks = yblocks < 1 ? 1 : yblocks;
    dim3 blocks(nInputPlane,yblocks);
    dim3 threads(32,8);

    // sync
    cudaDeviceSynchronize();

    // run updateGradInput kernel
    subgradinput <<<blocks, threads>>> (gradInput_data, gradOutput_data, weight_data,
                                        nInputPlane, nInputRows, nInputCols, kH, kW, dH, dW);
  } else {
    long nInputCols = input->size[3];
    long nInputRows = input->size[2];
    long nbatch = input->size[0];

    float *weight_data = THCudaTensor_data(weight);
    float *gradOutput_data = THCudaTensor_data(gradOutput);
    float *gradInput_data;

    THCudaTensor_resizeAs(gradInput, input);
    THCudaTensor_zero(gradInput);
    gradInput_data = THCudaTensor_data(gradInput);

    // cuda blocks & threads:
    int yblocks = floor(16 / nInputPlane);
    yblocks = yblocks < 1 ? 1 : yblocks;
    dim3 blocks(nInputPlane*nbatch,yblocks);
    dim3 threads(32,8);

    // sync
    cudaDeviceSynchronize();

    // run updateGradInput kernel
    subgradinput <<<blocks, threads>>> (gradInput_data, gradOutput_data, weight_data,
                                        nInputPlane, nInputRows, nInputCols, kH, kW, dH, dW);
  }

  // sync & clean
  cudaDeviceSynchronize();

  // check for errors
  cudaError_t err = cudaGetLastError();
  if (err != cudaSuccess) {
    printf("error in SpatialSubsampling.updateGradInput: %s\n", cudaGetErrorString(err));
    THError("aborting");
  }
  return 1;
}

static int cunn_SpatialSubSampling_accGradParameters(lua_State *L)
{
  THCudaTensor *input = (THCudaTensor *)luaT_checkudata(L, 2, torch_CudaTensor_id);
  THCudaTensor *gradOutput = (THCudaTensor *)luaT_checkudata(L, 3, torch_CudaTensor_id);
  int kW = luaT_getfieldcheckint(L, 1, "kW");
  int kH = luaT_getfieldcheckint(L, 1, "kH");
  int dW = luaT_getfieldcheckint(L, 1, "dW");
  int dH = luaT_getfieldcheckint(L, 1, "dH");
  int nInputPlane = luaT_getfieldcheckint(L, 1, "nInputPlane");
  float scale = luaL_optnumber(L, 4, 1);

  luaL_argcheck(L, dW == kW, 1, "dW and kW must be equal (this will be fixed soon)");
  luaL_argcheck(L, dH == kH, 1, "dH and kH must be equal (this will be fixed soon)");

  THCudaTensor *gradWeight = (THCudaTensor *)luaT_getfieldcheckudata(L, 1, "gradWeight", torch_CudaTensor_id);
  THCudaTensor *gradBias = (THCudaTensor *)luaT_getfieldcheckudata(L, 1, "gradBias", torch_CudaTensor_id);

  if (input->nDimension == 3) {
    long nInputCols = input->size[2];
    long nInputRows = input->size[1];

    float *gradWeight_data = THCudaTensor_data(gradWeight);
    float *gradBias_data = THCudaTensor_data(gradBias);
    float *gradOutput_data = THCudaTensor_data(gradOutput);
    float *input_data;

    input = THCudaTensor_newContiguous(input);
    input_data = THCudaTensor_data(input);

    // cuda blocks & threads:
    dim3 blocks(nInputPlane);
    dim3 threads(32,8);

    // sync
    cudaDeviceSynchronize();

    // run gradweight kernel
    subgradweight <<<blocks, threads>>> (input_data, gradOutput_data, gradWeight_data, gradBias_data,
                                         nInputPlane, nInputRows, nInputCols, kH, kW, dH, dW, scale);
  } else {
    long nInputCols = input->size[3];
    long nInputRows = input->size[2];
    long nbatch = input->size[0];

    float *gradWeight_data = THCudaTensor_data(gradWeight);
    float *gradBias_data = THCudaTensor_data(gradBias);
    float *gradOutput_data = THCudaTensor_data(gradOutput);
    float *input_data;

    input = THCudaTensor_newContiguous(input);
    input_data = THCudaTensor_data(input);

    // cuda blocks & threads:
    dim3 blocks(nInputPlane);
    dim3 threads(32,8);

    // sync
    cudaDeviceSynchronize();

    // run gradweight kernel
    long sl;
    for (sl=0; sl<nbatch; sl++) {
      subgradweight <<<blocks, threads>>> (input_data + sl*input->stride[0], 
                                           gradOutput_data + sl*gradOutput->stride[0], 
                                           gradWeight_data, gradBias_data,
                                           nInputPlane, nInputRows, nInputCols, kH, kW, dH, dW, scale);
    }
  }

  // sync & clean
  cudaDeviceSynchronize();
  THCudaTensor_free(input);

  // check for errors
  cudaError_t err = cudaGetLastError();
  if (err != cudaSuccess) {
    printf("error in SpatialSubsampling.accGradParameters: %s\n", cudaGetErrorString(err));
    THError("aborting");
  }
  return 0;
}

static const struct luaL_Reg cunn_SpatialSubSampling__ [] = {
  {"SpatialSubSampling_updateOutput", cunn_SpatialSubSampling_updateOutput},
  {"SpatialSubSampling_updateGradInput", cunn_SpatialSubSampling_updateGradInput},
  {"SpatialSubSampling_accGradParameters", cunn_SpatialSubSampling_accGradParameters},
  {NULL, NULL}
};

static void cunn_SpatialSubSampling_init(lua_State *L)
{
  luaT_pushmetaclass(L, torch_CudaTensor_id);
  luaT_registeratname(L, cunn_SpatialSubSampling__, "nn");
  lua_pop(L,1);
}
