#include "evaluate_accuracy.cuh"

#define THREADS_PER_BLOCK 1024

const char *_cudaGetErrorEnum(cublasStatus_t error)
{
    switch (error)
    {
    case CUBLAS_STATUS_SUCCESS:
        return "CUBLAS_STATUS_SUCCESS";

    case CUBLAS_STATUS_NOT_INITIALIZED:
        return "CUBLAS_STATUS_NOT_INITIALIZED";

    case CUBLAS_STATUS_ALLOC_FAILED:
        return "CUBLAS_STATUS_ALLOC_FAILED";

    case CUBLAS_STATUS_INVALID_VALUE:
        return "CUBLAS_STATUS_INVALID_VALUE";

    case CUBLAS_STATUS_ARCH_MISMATCH:
        return "CUBLAS_STATUS_ARCH_MISMATCH";

    case CUBLAS_STATUS_MAPPING_ERROR:
        return "CUBLAS_STATUS_MAPPING_ERROR";

    case CUBLAS_STATUS_EXECUTION_FAILED:
        return "CUBLAS_STATUS_EXECUTION_FAILED";

    case CUBLAS_STATUS_INTERNAL_ERROR:
        return "CUBLAS_STATUS_INTERNAL_ERROR";
    }

    return "<unknown>";
}

/* Start computing the softmax on the device */
__global__ void log_kernel(float *Z_d, int nb_LigneZ, int nb_ColZ, float *d_logP)
{
    int case_id = blockIdx.x * blockDim.x + threadIdx.x;
    int i = case_id % nb_LigneZ; // line id
    int j = case_id / nb_LigneZ; // col id

    /* If j is coherent */
    if (j < nb_ColZ)
    {
        /* Replace by the log */
        d_logP[IDX2C(i, j, nb_LigneZ)] = logf(Z_d[IDX2C(i, j, nb_LigneZ)]);
    }
}

/* Compute the sum of the diagonal of the product of A and B sum(diag(Yt*P)) */
__global__ void sum_diag_kernel(fmatrix d_A, float *J)
{
    int case_id = blockIdx.x * blockDim.x + threadIdx.x;
    int j = case_id;
    int i = case_id;

    /* If j is coherent */
    if (j < d_A.cols && i < d_A.rows)
    {
        atomicAdd(J, getfm(d_A, i, j));
    }
}

__global__ void evaluate_accuracy_kernel(fmatrix d_Y, fmatrix d_Z, int *count)
{
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < d_Z.cols)
    {
        float z_max = getfm(d_Z, 0, idx);
        int i_max = 0;
        for (int i = 1; i < d_Z.rows; ++i)
        {
            if (getfm(d_Z, i, idx) > z_max)
            {
                z_max = getfm(d_Z, i, idx);
                i_max = i;
            }
        }
        if (getfm(d_Y, i_max, idx) >= 0.5f)
        {
            atomicAdd(count, 1);
        }
    }
}

float evaluate_accuracy(cublasHandle_t handle, fmatrix d_W, fmatrix d_X, fmatrix d_Y, fmatrix d_Z, bool verbose /* = true*/)
{
    assert(d_Y.cols == d_Z.cols);
    assert(d_Y.rows == d_Z.rows);
    fmatrix_assert(d_Z);

    float alpha = 1.0f;
    float beta = 1.0f;
    if (verbose)
    {
        printf("dw rows %d, dw cols %d, dX rows %d, dX cols %d, dZ rows %d, dZ cols %d\n", d_W.rows, d_W.cols, d_X.rows, d_X.cols, d_Z.rows, d_Z.cols);
        printf("m %d, n %d, k %d\n", d_W.cols, d_X.cols, d_W.rows);
    }
    cublasStatus_t multstat = cublasSgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, d_W.cols, d_X.cols, d_W.rows, &alpha, d_W.data, d_W.rows, d_X.data, d_X.rows, &beta, d_Z.data, d_Z.rows);

    if (multstat != CUBLAS_STATUS_SUCCESS)
    {
        printf("CUBLAS matrix multiplication failed 1\n");
        printf("%s\n", _cudaGetErrorEnum(multstat));
        gpuErrchk(cudaPeekAtLastError());
    }

    int true_class = 0;

    int *d_count = 0;
    gpuErrchk(cudaMalloc((void **)&d_count, sizeof(int)));
    gpuErrchk(
        cudaMemcpy(d_count, &true_class, sizeof(int), cudaMemcpyHostToDevice));

    int threadsPerBlock = d_Z.cols;
    int blocksPerGrid = 1;
    if (threadsPerBlock > THREADS_PER_BLOCK)
    {
        blocksPerGrid = (threadsPerBlock - 1) / THREADS_PER_BLOCK + 1;
        threadsPerBlock = THREADS_PER_BLOCK;
    }
    evaluate_accuracy_kernel<<<blocksPerGrid, threadsPerBlock>>>(d_Y, d_Z, d_count);
    device_synchronize();
    gpuErrchk(cudaPeekAtLastError());

    gpuErrchk(
        cudaMemcpy(&true_class, d_count, sizeof(int), cudaMemcpyDeviceToHost));

    int nb_tested = d_X.cols;
    if (verbose)
    {
        printf("Correct results: %d out of %d\n", true_class, nb_tested);
        printf("Accuracy: %f\n", (float)true_class / (float)nb_tested);
    }

    return (float)true_class / (float)d_Z.cols;
}

float evaluate_logloss(cublasHandle_t handle, fmatrix d_P, fmatrix d_Y, bool verbose /* =true */)
{
    assert(d_Y.cols == d_P.cols);
    assert(d_Y.rows == d_P.rows);

    /* One thread per element */
    int thread_nb = d_P.rows * d_P.cols;
    dim3 dimGrid(1 + (thread_nb / THREADS_PER_BLOCK));
    dim3 dimBlock(THREADS_PER_BLOCK);

    /* Create the matrix which will contain the log of P */
    fmatrix d_logP = fmatrix_create_on_device(d_P.rows, d_P.cols);

    /* Compute the log */
    log_kernel<<<dimGrid, dimBlock>>>(d_P.data, d_P.rows, d_P.cols, d_logP.data);
    gpuErrchk(cudaPeekAtLastError());

    fmatrix d_Z = fmatrix_create_on_device(d_Y.cols, d_P.cols);

    float J;
    float *d_J = NULL;
    cudaMalloc((void **)&d_J, sizeof(float));

    float alpha = -1.0f;
    float beta = 0.0f;
    // dZ =dY^T*dP

    if (verbose)
    {
        printf("dY rows %d, dY cols %d, dP rows %d, dP cols %d, dZ rows %d, dZ cols %d\n", d_Y.rows, d_Y.cols, d_P.rows, d_P.cols, d_Z.rows, d_Z.cols);
        printf("m %d, n %d, k %d\n", d_Y.cols, d_P.cols, d_Y.rows);
    }
    cublasStatus_t multstat = cublasSgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, d_Y.cols, d_logP.cols, d_Y.rows, &alpha, d_Y.data, d_Y.rows, d_logP.data, d_logP.rows, &beta, d_Z.data, d_Z.rows);
    if (multstat != CUBLAS_STATUS_SUCCESS)
    {
        printf("CUBLAS matrix multiplication failed 2\n");
        printf("%s\n", _cudaGetErrorEnum(multstat));
        gpuErrchk(cudaPeekAtLastError());
    }

    /* One thread per column */
    thread_nb = d_Z.cols;
    dimGrid = dim3(1 + (thread_nb / THREADS_PER_BLOCK));
    dimBlock = dim3(THREADS_PER_BLOCK);

    fmatrix_assert(d_Z);

    sum_diag_kernel<<<dimGrid, dimBlock>>>(d_Z, d_J); //d_Z.rows, d_Z.cols, &J);
    gpuErrchk(cudaPeekAtLastError());

    if (verbose)
    {
        printf("In logloss: d_P\n");
        fmatrix_device_print(d_P);

        printf("In logloss: d_logP\n");
        fmatrix_device_print(d_logP);

        printf("In logloss: d_Y\n");
        fmatrix_device_print(d_Y);

        printf("In logloss: dZ = -dY^T*dP\n");
        fmatrix_device_print(d_Z);
    }

    cudaMemcpy(&J, d_J, sizeof(float), cudaMemcpyDeviceToHost);

    fmatrix_free_on_device(&d_logP);
    fmatrix_free_on_device(&d_Z);

    return J;
}
