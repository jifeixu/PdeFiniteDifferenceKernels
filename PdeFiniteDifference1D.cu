#include "PdeFiniteDifference1D.cuh"

#include <CuBlasWrappers.cuh>
#include <BufferInitializer.cuh>
#include <MemoryManager.cuh>

#include <array>

namespace detail
{
	/**
	*	Evolve the solution using the time discretizer.
	*	N.B.: solution is a memory tile, as some solver might require the solution history
	*	N.B.2: if provided, workBuffer is a previously allocated buffer used for matrix-vector multiplication
	*/
	int _Advance1D(MemoryTile solution, const MemoryCube timeDiscretizer, MemoryTile workBuffer, const bool overwriteBuffer)
	{
		// this is to support multi-step algorithms: each solution is multiplied by a different time discretizer
		MemoryBuffer _solution(solution.pointer, solution.nRows, solution.memorySpace, solution.mathDomain);
		MemoryBuffer _buffer(workBuffer.pointer, workBuffer.nRows, workBuffer.memorySpace, workBuffer.mathDomain);
		MemoryTile _timeDiscretizer(timeDiscretizer.pointer, timeDiscretizer.nRows, timeDiscretizer.nCols, timeDiscretizer.memorySpace, timeDiscretizer.mathDomain);

		// work out where to write the matrix-vector dot-product
		MemoryBuffer *_out, *_in;
		if (overwriteBuffer)
		{
			_out = &_buffer;
			_in = &_solution;
		}
		else
		{
			_in = &_buffer;
			_out = &_solution;
		}
		const ptr_t inPtr = _in->pointer;
		const ptr_t outPtr = _out->pointer;

		// multiplicate each solution with the respective time discretizer
		for (unsigned i = 0; i < solution.nCols; ++i)
		{
			_buffer.pointer = workBuffer.pointer + i * _buffer.TotalSize();
			_solution.pointer = solution.pointer + i * _solution.TotalSize();
			_timeDiscretizer.pointer = timeDiscretizer.pointer + i * _timeDiscretizer.TotalSize();
			_Dot(*_out, _timeDiscretizer, *_in);
		}
		int err = cudaGetLastError();

		// add the partial results into the latest solution
		
		for (unsigned i = 1; i < solution.nCols; ++i)
		{
			// cumulative sum of each step contribution into the first column
			_out->pointer = outPtr;
			_in->pointer = outPtr + i * _in->TotalSize();  // re-use _in for convenience!
			_AddEqual(*_out, *_in);
			err = cudaGetLastError();

			// copy the input solution into the older solution buffers
			_out->pointer = _in->pointer;
			_in->pointer = inPtr + i * _in->TotalSize();
			_DeviceToDeviceCopy(*_out, *_in);
			err = cudaGetLastError();
		}
		
		return cudaGetLastError();
	}

	/**
	*	Sets the boundary conditions in the solution. It's a bit of a waste calling a kernel<<<1, 1>>>, but I found no other good way!
	*/
	int _SetBoundaryConditions1D(MemoryTile solution, const MemoryCube timeDiscretizer, const FiniteDifferenceInput1D input)
	{
		if (input.boundaryConditions.left.type == BoundaryConditionType::Periodic && input.boundaryConditions.right.type == BoundaryConditionType::Periodic)
			return 0;  // no need to call the kernel!

		switch (solution.mathDomain)
		{
			case MathDomain::Float:
				CUDA_CALL_XY(__SetBoundaryConditions1D__<float>, 1, 1, (float*)solution.pointer, (float*)timeDiscretizer.pointer, (float)input.boundaryConditions.left.value, (float)input.boundaryConditions.right.value, input.boundaryConditions.left.type, input.boundaryConditions.right.type, (float*)input.grid.pointer, solution.nRows);
				break;
			case MathDomain::Double:
				CUDA_CALL_XY(__SetBoundaryConditions1D__<double>, 1, 1, (double*)solution.pointer, (double*)timeDiscretizer.pointer, input.boundaryConditions.left.value, input.boundaryConditions.right.value, input.boundaryConditions.left.type, input.boundaryConditions.right.type, (double*)input.grid.pointer, solution.nRows);
				break;
			default:
				return CudaKernelException::_NotImplementedException;
		}
		return cudaGetLastError();
	}

	// N is the size of the Butcher tableau table
	// aMatrix is the lower triangular tableau matrix. If the diagonal is populated the method is an implicit RK
	// bvector is the vector used for composing the "k"'s 
	// WARNING: This doesn't support dense aMatrix, but only lower triangular
	template<unsigned N>
	int _MakeRungeKuttaDiscretizer(const std::array<double, N * (N + 1) / 2>& aMatrix, 
								   const std::array<double, N>& bVector, 
								   const double dt, 
								   const MemoryTile& spaceDiscretizer, 
								   const MemoryTile& timeDiscretizer)
	{
		auto getLowerTriangularIndex = [](const unsigned i, const unsigned j) { return j + i * (i + 1) / 2; };

		MemoryCube kVector(0, timeDiscretizer.nRows, timeDiscretizer.nCols, N, timeDiscretizer.memorySpace, timeDiscretizer.mathDomain);
		_Alloc(kVector);

		MemoryTile kRhs(timeDiscretizer); // kRhs is a working buffer that stores k_i r.h.s.
		_Alloc(kRhs);

		// loop for calculating k_i
		for (unsigned i = 0; i < N; ++i)
		{
			_Eye(kRhs);

			// aMatrix * k multiplication
			for (unsigned j = 0; j < i; ++j)
			{
				MemoryTile k_j;
				extractMatrixBufferFromCube(k_j, kVector, j);
				if (aMatrix[getLowerTriangularIndex(i, j)] != 0.0)
					_AddEqualMatrix(kRhs, k_j, MatrixOperation::None, MatrixOperation::None, aMatrix[getLowerTriangularIndex(i, j)] * dt);
			}

			MemoryTile k_i;
			extractMatrixBufferFromCube(k_i, kVector, i);
			_Multiply(k_i, spaceDiscretizer, kRhs, spaceDiscretizer.nRows, kRhs.nRows);

			if (aMatrix[getLowerTriangularIndex(i, i)] != 0.0)
			{
				// re-set kRhs instead of allocating kLhs
				_Eye(kRhs);
				_AddEqual(kRhs, spaceDiscretizer, -aMatrix[getLowerTriangularIndex(i, i)] * dt);
				_Solve(kRhs, k_i);
			}
		}

		//now that all kVector items are set, fo the b * k multiplication
		_Eye(timeDiscretizer);  // initialise time discretizer with the identity
		for (unsigned j = 0; j < N; ++j)
		{
			MemoryTile k_j;
			extractMatrixBufferFromCube(k_j, kVector, j);
			_AddEqualMatrix(timeDiscretizer, k_j, MatrixOperation::None, MatrixOperation::None, bVector[j] * dt);
		}

		_Free(kVector);
		_Free(kRhs);

		return cudaGetLastError();
	}


	int _MakeRungeKuttaGaussLegendre(const double dt,
									 const MemoryTile& spaceDiscretizer,
									 const MemoryTile& timeDiscretizer)
	{
		constexpr double a00 = { .25 };
		constexpr double sqrt3 = { 1.73205080756888 };
		constexpr double a01 = { .25 - sqrt3 / 6.0 };
		constexpr double a10 = { .25 + sqrt3 / 6.0 };
		constexpr double a11 = { .25 };

		MemoryTile eye(timeDiscretizer);
		_Alloc(eye);
		_Eye(eye);

		MemoryTile A(timeDiscretizer);
		_Alloc(A);
		_Add(A, eye, spaceDiscretizer, -a00 * dt);

		MemoryTile B(timeDiscretizer);
		_Alloc(B);
		_DeviceToDeviceCopy(B, spaceDiscretizer);
		_Solve(A, B);
		_Scale(B, a10 * dt);

		MemoryTile C(timeDiscretizer);
		_Alloc(C);
		_DeviceToDeviceCopy(C, B); 
		_Scale(C, a01 * dt);
		_AddEqualMatrix(C, eye, MatrixOperation::None, MatrixOperation::None, a11 * dt);

		MemoryTile C2(timeDiscretizer);
		_Alloc(C2);
		_DeviceToDeviceCopy(C2, C);
		_Multiply(C, spaceDiscretizer, C2, spaceDiscretizer.nRows, C2.nRows);
		_Free(C2);

		MemoryTile D(timeDiscretizer);
		_Alloc(D);
		_Add(D, C, eye, -1);

		MemoryTile E(timeDiscretizer);
		_Alloc(E);
		_Add(E, eye, B);

		MemoryTile k_2(timeDiscretizer);
		_Alloc(k_2);
		_Multiply(k_2, spaceDiscretizer, E, spaceDiscretizer.nRows, E.nRows);
		_Solve(D, k_2);

		MemoryTile F(timeDiscretizer);
		_Alloc(F);
		_Add(F, eye, k_2, a01 * dt);

		MemoryTile k_1(timeDiscretizer);
		_Alloc(k_1);
		_Multiply(k_1, spaceDiscretizer, F, spaceDiscretizer.nRows, E.nRows);
		_Solve(A, k_1);

		_Eye(timeDiscretizer);
		_AddEqualMatrix(k_1, k_2);
		_AddEqualMatrix(timeDiscretizer, k_1, MatrixOperation::None, MatrixOperation::None, .5 * dt);

		_Free(eye);
		_Free(A);
		_Free(B);
		_Free(C);
		_Free(D);
		_Free(E);
		_Free(F);

		_Free(k_1);
		_Free(k_2);

		return cudaGetLastError();
	}
}

EXTERN_C
{
	EXPORT int _MakeSpaceDiscretizer1D(MemoryTile spaceDiscretizer, const FiniteDifferenceInput1D input)
	{
		switch (spaceDiscretizer.mathDomain)
		{
			case MathDomain::Float:
				CUDA_CALL_SINGLE(__MakeSpaceDiscretizer1D__<float>, (float*)spaceDiscretizer.pointer, (float*)input.grid.pointer, (float*)input.velocity.pointer, (float*)input.diffusion.pointer, input.boundaryConditions.left.type, input.boundaryConditions.right.type, (float)input.dt, input.grid.size);
				break;
			case MathDomain::Double:
				CUDA_CALL_DOUBLE(__MakeSpaceDiscretizer1D__<double>, (double*)spaceDiscretizer.pointer, (double*)input.grid.pointer, (double*)input.velocity.pointer, (double*)input.diffusion.pointer, input.boundaryConditions.left.type, input.boundaryConditions.right.type, input.dt, input.grid.size);
				break;
			default:
				return CudaKernelException::_NotImplementedException;
		}
		return cudaGetLastError();
	}

	EXPORT int _MakeTimeDiscretizer1D(MemoryCube timeDiscretizer, const MemoryTile spaceDiscretizer, const FiniteDifferenceInput1D input)
	{
		MemoryTile _timeDiscretizer;
		extractMatrixBufferFromCube(_timeDiscretizer, timeDiscretizer, 0);

		switch (input.solverType)
		{
			case SolverType::ExplicitEuler:
				// A = I + L * dt
				assert(timeDiscretizer.nCubes == 1);

				_Eye(_timeDiscretizer);
				_AddEqual(_timeDiscretizer, spaceDiscretizer, input.dt);
				break;

			case SolverType::ImplicitEuler:
				// A = (I - L * dt)^(-1)
				assert(timeDiscretizer.nCubes == 1);

				_Eye(_timeDiscretizer);
				_AddEqual(_timeDiscretizer, spaceDiscretizer, -input.dt);
				_Invert(_timeDiscretizer);
				break;

			case SolverType::CrankNicolson:
			{
				// A = (I - L * .5 * dt)^(-1) * (I + L * .5 * dt)
				assert(timeDiscretizer.nCubes == 1);

				_Eye(_timeDiscretizer);

				// copy timeDiscretizer into leftOperator volatile buffer
				MemoryTile leftOperator(_timeDiscretizer);
				_Alloc(leftOperator);
				_DeviceToDeviceCopy(leftOperator, _timeDiscretizer);

				// left and right operator
				_AddEqual(leftOperator, spaceDiscretizer, -.5 * input.dt);  // A = I - .5 * dt
				_AddEqual(timeDiscretizer, spaceDiscretizer, .5 * input.dt);  // B = I + .5 * dt
				_Solve(leftOperator, _timeDiscretizer);

				_Free(leftOperator);
			}
			break;

			case SolverType::AdamsBashforth2:
				// A_{n + 1} = (I + L * 1.5 * dt)
				assert(timeDiscretizer.nCubes == 2);
				
				_Eye(_timeDiscretizer);
				_AddEqual(_timeDiscretizer, spaceDiscretizer, 1.5 * input.dt);  // A = I + 1.5 * dt

				// A_{n} = - L * .5 * dt
				_timeDiscretizer.pointer += _timeDiscretizer.nRows * _timeDiscretizer.nCols * _timeDiscretizer.ElementarySize();
				_DeviceToDeviceCopy(_timeDiscretizer, spaceDiscretizer);
				_Scale(_timeDiscretizer, -.5 * input.dt);
				break;

			case SolverType::AdamsMouldon2:
			{
				// A_{n + 1} = (I - L * 5 / 12 * dt)^(-1) * (I + L * 2.0 / 3.0 * dt)
				assert(timeDiscretizer.nCubes == 2);

				// copy timeDiscretizer into leftOperator volatile buffer
				MemoryTile leftOperator(_timeDiscretizer);
				_Alloc(leftOperator);
				_Eye(leftOperator);
				_AddEqual(leftOperator, spaceDiscretizer, -5.0 / 12.0 * input.dt);  // A = I - .5 * dt

				_Eye(_timeDiscretizer);
				_AddEqual(_timeDiscretizer, spaceDiscretizer, 2.0 / 3.0 * input.dt);  // A = I - .5 * dt
				_Solve(leftOperator, _timeDiscretizer);

				// A_{n} = (I - L * 5 / 12 * dt)^(-1) * (- L *  1.0 / 12.0 * dt)
				_timeDiscretizer.pointer += _timeDiscretizer.nRows * _timeDiscretizer.nCols * _timeDiscretizer.ElementarySize();
				_DeviceToDeviceCopy(_timeDiscretizer, spaceDiscretizer);
				_Scale(_timeDiscretizer, -1.0 / 12.0 * input.dt);
				_Solve(leftOperator, _timeDiscretizer);
			}
			break;

			case SolverType::RungeKuttaRalston:
				detail::_MakeRungeKuttaDiscretizer<2>({ 0, 
													    2.0 / 3.0, 0 }, 
														{ .25, .75 }, input.dt, spaceDiscretizer, _timeDiscretizer);
				break;
			case SolverType::RungeKutta3:
				detail::_MakeRungeKuttaDiscretizer<3>({ 0, 
													    .5, .0, 
													    -1,  2, 0 }, 
														{ 1.0 / 6.0, 2.0 / 3.0, 1.0 / 6.0 }, input.dt, spaceDiscretizer, _timeDiscretizer);
				break;
			case SolverType::RungeKutta4:
				detail::_MakeRungeKuttaDiscretizer<4>({ 0, 
													   .5, .0, 
													    0, .5, 0,
				                                        0,  0, 1, 0}, 
														{ 1.0 / 6.0, 1.0 / 3.0, 1.0 / 3.0, 1.0 / 6.0 }, input.dt, spaceDiscretizer, _timeDiscretizer);
				break;
			case SolverType::RungeKuttaThreeEight:
				detail::_MakeRungeKuttaDiscretizer<4>({ 0,
													   1.0 / 3.0, .0,
													  -1.0 / 3.0,  1, 0,
													           1, -1, 1, 0 },
													    { 1.0 / 8.0, 3.0 / 8.0, 3.0 / 8.0, 1.0 / 8.0 }, input.dt, spaceDiscretizer, _timeDiscretizer);
				break;
			case SolverType::RungeKuttaGaussLegendre4:
				detail::_MakeRungeKuttaGaussLegendre(input.dt, spaceDiscretizer, _timeDiscretizer);
				break;
			default:
				return CudaKernelException::_NotImplementedException;
		}

		return cudaGetLastError();
	}

	EXPORT int _Iterate1D(MemoryTile solution, const MemoryCube timeDiscretizer, const FiniteDifferenceInput1D input, const unsigned nSteps)
	{
		// allocate a volatile buffer, used for the matrix-vector dot-product
		MemoryTile workBuffer = MemoryTile(solution);
		_Alloc(workBuffer);

		bool overwriteBuffer = true;
		int err = 0;
		for (unsigned n = 0; n < nSteps; ++n)
		{
			err = detail::_Advance1D(solution, timeDiscretizer, workBuffer, overwriteBuffer);
			if (err)
				return err;

			// set boundary conditions
			err = detail::_SetBoundaryConditions1D(overwriteBuffer ? workBuffer : solution, timeDiscretizer, input);
			if (err)
				return err;

			overwriteBuffer = !overwriteBuffer;
		}

		if (!overwriteBuffer)  // need the negation here, as it's set at the end of the loop!
			// copy the result back from working buffer and free it
			_DeviceToDeviceCopy(solution, workBuffer);
		
		_Free(workBuffer);

		return cudaGetLastError();
	}
}

template <typename T>
GLOBAL void __MakeSpaceDiscretizer1D__(T* RESTRICT spaceDiscretizer, const T* RESTRICT grid, const T* RESTRICT velocity, const T* RESTRICT diffusion, const BoundaryConditionType leftBoundaryConditionType, const BoundaryConditionType rightBoundaryConditionType, const T dt, const unsigned sz)
{
	CUDA_FUNCTION_PROLOGUE;

	for (unsigned i = tid + 1; i < sz - 1; i += step)
	{
		const T dxPlus = grid[i + 1] - grid[i];
		const T dxMinus = grid[i] - grid[i - 1];
		const T dx = dxPlus + dxMinus;

		// 3-point centered spatial finite difference that accounts for uneven space mesh
		spaceDiscretizer[i + sz * (i - 1)] = (-dxPlus  * velocity[i] + static_cast<T>(2.0) * diffusion[i]) / (dxMinus * dx);
		spaceDiscretizer[i + sz * (i + 1)] = (dxMinus * velocity[i] + static_cast<T>(2.0) * diffusion[i]) / (dxPlus  * dx);
		spaceDiscretizer[i + sz * i] = -spaceDiscretizer[i + sz * (i - 1)] - spaceDiscretizer[i + sz * (i + 1)];
	}
}

template <typename T>
GLOBAL void __SetBoundaryConditions1D__(T* RESTRICT solution, T* RESTRICT timeDiscretizer, const T leftValue, const T rightValue, const BoundaryConditionType leftBoundaryConditionType, const BoundaryConditionType rightBoundaryConditionType, const T* RESTRICT grid, const unsigned sz)
{
	unsigned int tid = blockIdx.x * blockDim.x + threadIdx.x;

	// update boundary condition only for the most recent solution, which is the first column of the solution matrix
	if (tid == 0)
	{
		// Dirichlet:  1 0 ...  0 0
		//			   0 0 ...  0 0
		//			   0 0 ...  0 1

		// Neumann: -2 1 ...  0 0
		//			 0 0 ...  0 0
		//			 0 0 ... -1 0

		// Periodic: -1 0 ... 1  0
		//			  0 0 ... 0  0
		//			  0 1 ... 0 -1

		switch (leftBoundaryConditionType)
		{
			case BoundaryConditionType::Dirichlet:
				solution[0] = leftValue;
				break;
			case BoundaryConditionType::Neumann:
				solution[0] = solution[1] - leftValue * (grid[1] - grid[0]);
				break;
			case BoundaryConditionType::Periodic:
				solution[0] = solution[sz - 2];
				break;
			default:
				break;
		}

		switch (rightBoundaryConditionType)
		{
			case BoundaryConditionType::Dirichlet:
				solution[sz - 1] = rightValue;
				break;
			case BoundaryConditionType::Neumann:
				solution[sz - 1] = solution[sz - 2] - rightValue * (grid[sz - 1] - grid[sz - 2]);
				break;
			case BoundaryConditionType::Periodic:
				solution[sz - 1] = solution[1];
			default:
				break;
		}
	}
}