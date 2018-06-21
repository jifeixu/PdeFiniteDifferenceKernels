#pragma once

#include <Flags.cuh>
#include <Types.h>

EXTERN_C
{
	/**
	* Defines the time discretizer type
	*/
	enum class SolverType
	{
		Null = 0,

		/**
		* Single-Step
		*/
		ExplicitEuler = 1,
		ImplicitEuler = 2,
		CrankNicolson = 3,

		/*
		* Runge-Kutta
		*/
		RungeKuttaRalston = 4,         // 2nd order RK
		RungeKutta3 = 5,               // 3rd order RK
		RungeKutta4 = 6,               // 4th order RK
		RungeKuttaThreeEight = 7,      // Not so popular 3/8 method (4th order)
		RungeKuttaGaussLegendre4 = 8,  // 4th order Gauss-Legendre

		/**
		* Richardson Extrapolation
		*/
	    RichardsonExtrapolation2 = 9, 
		RichardsonExtrapolation3 = 10,

		/**
		* Multi-Step
		*/
	    AdamsBashforth2 = 11,
		AdamsMouldon2 = 12,

		__BEGIN__ = 1,
		__END__ = 13
	};

	static constexpr unsigned getNumberOfSteps(const SolverType solverType)
	{
		switch (solverType)
		{
			case SolverType::AdamsBashforth2:
			case SolverType::AdamsMouldon2:
				return 2;
			default:
				return 1;
		}
	}

	/**
	* Defines how to discretize on the space dimension 
	*/
	enum class SpaceDiscretizerType
	{
		Null = 0,

		Centered = 1,
		Upwind = 2,
		LaxWendroff = 3
	};

	enum class BoundaryConditionType
	{
		Null = 0,

		Dirichlet = 1,
		Neumann = 2,
		Periodic = 3,
	};

	struct BoundaryCondition
	{
		BoundaryConditionType type = BoundaryConditionType::Neumann;
		double value = 0.0;

		BoundaryCondition(const BoundaryConditionType type = BoundaryConditionType::Neumann, const double value = 0.0)
			: type(type), value(value)
		{
		}

		virtual ~BoundaryCondition() noexcept = default;
		BoundaryCondition(const BoundaryCondition& rhs) noexcept = default;
		BoundaryCondition(BoundaryCondition&& rhs) noexcept = default;
		BoundaryCondition& operator=(const BoundaryCondition& rhs) noexcept = default;
		BoundaryCondition& operator=(BoundaryCondition&& rhs) noexcept = default;
	};

	class BoundaryCondition1D
	{
	public:
		BoundaryCondition left = BoundaryCondition();
		BoundaryCondition right = BoundaryCondition();

		BoundaryCondition1D(BoundaryCondition left = BoundaryCondition(), BoundaryCondition right = BoundaryCondition())
			: left(left), right(right)
		{
		}

		virtual ~BoundaryCondition1D() noexcept = default;
		BoundaryCondition1D(const BoundaryCondition1D& rhs) noexcept = default;
		BoundaryCondition1D(BoundaryCondition1D&& rhs) noexcept = default;
		BoundaryCondition1D& operator=(const BoundaryCondition1D& rhs) noexcept = default;
		BoundaryCondition1D& operator=(BoundaryCondition1D&& rhs) noexcept = default;
	};

	class BoundaryCondition2D : public BoundaryCondition1D
	{
	public:
		BoundaryCondition down = BoundaryCondition();
		BoundaryCondition up = BoundaryCondition();

		BoundaryCondition2D(BoundaryCondition left = BoundaryCondition(), BoundaryCondition right = BoundaryCondition(), BoundaryCondition down = BoundaryCondition(), BoundaryCondition up = BoundaryCondition())
			: BoundaryCondition1D(left, right), down(down), up(up)
		{
		}

		virtual ~BoundaryCondition2D() noexcept = default;
		BoundaryCondition2D(const BoundaryCondition2D& rhs) noexcept = default;
		BoundaryCondition2D(BoundaryCondition2D&& rhs) noexcept = default;
		BoundaryCondition2D& operator=(const BoundaryCondition2D& rhs) noexcept = default;
		BoundaryCondition2D& operator=(BoundaryCondition2D&& rhs) noexcept = default;
	};

	struct FiniteDifferenceInput1D
	{
		/**
		* Time discretization mesh size
		*/
		double dt;

		/**
		* Space discretization mesh
		*/
		MemoryBuffer grid;

		/**
		* Advection coefficient
		*/
		MemoryBuffer velocity; 

		/**
		* Diffusion coefficient
		*/
		MemoryBuffer diffusion;

		/**
		* Solver Type
		*/
		SolverType solverType;

		/**
		* Space Discretizer Type
		*/
		SpaceDiscretizerType spaceDiscretizerType;

		/**
		* Left/Right boundary conditions
		*/
		BoundaryCondition1D boundaryConditions;

		FiniteDifferenceInput1D(double dt,
								MemoryBuffer grid,
								MemoryBuffer velocity,
								MemoryBuffer diffusion,
								SolverType solverType,
								SpaceDiscretizerType spaceDiscretizerType,
								BoundaryCondition1D boundaryConditions)
			:
			dt(dt),
			grid(grid),
			velocity(velocity),
			diffusion(diffusion),
			solverType(solverType),
			spaceDiscretizerType(spaceDiscretizerType),
			boundaryConditions(boundaryConditions)
		{
		}

		virtual ~FiniteDifferenceInput1D() noexcept = default;
		FiniteDifferenceInput1D(const FiniteDifferenceInput1D& rhs) noexcept = default;
		FiniteDifferenceInput1D(FiniteDifferenceInput1D&& rhs) noexcept = default;
		FiniteDifferenceInput1D& operator=(const FiniteDifferenceInput1D& rhs) noexcept = default;
		FiniteDifferenceInput1D& operator=(FiniteDifferenceInput1D&& rhs) noexcept = default;
	};

	struct FiniteDifferenceInput2D
	{
		/**
		* Time discretization mesh size
		*/
		double dt;

		/**
		* Space discretization mesh - x direction
		*/
		MemoryBuffer xGrid;
		/**
		* Space discretization mesh - y direction
		*/
		MemoryBuffer yGrid;

		/**
		* Advection coefficient - x direction
		*/
		MemoryBuffer xVelocity;
		/**
		* Advection coefficient - y direction
		*/
		MemoryBuffer yVelocity;

		/**
		* Diffusion coefficient
		*/
		MemoryBuffer diffusion;

		/**
		* Solver Type
		*/
		SolverType solverType;

		/**
		* Space Discretizer Type
		*/
		SpaceDiscretizerType spaceDiscretizerType;

		/**
		* Left/Right boundary conditions
		*/
		BoundaryCondition2D boundaryConditions;

		FiniteDifferenceInput2D(double dt,
								MemoryBuffer xGrid,
								MemoryBuffer yGrid,
								MemoryBuffer xVelocity,
								MemoryBuffer yVelocity,
								MemoryBuffer diffusion,
								SolverType solverType,
								SpaceDiscretizerType spaceDiscretizerType,
								BoundaryCondition2D boundaryConditions)
			:
			dt(dt),
			xGrid(xGrid),
			yGrid(yGrid),
			xVelocity(xVelocity),
			yVelocity(yVelocity),
			diffusion(diffusion),
			solverType(solverType),
			spaceDiscretizerType(spaceDiscretizerType),
			boundaryConditions(boundaryConditions)
		{
		}

		virtual ~FiniteDifferenceInput2D() noexcept = default;
		FiniteDifferenceInput2D(const FiniteDifferenceInput2D& rhs) noexcept = default;
		FiniteDifferenceInput2D(FiniteDifferenceInput2D&& rhs) noexcept = default;
		FiniteDifferenceInput2D& operator=(const FiniteDifferenceInput2D& rhs) noexcept = default;
		FiniteDifferenceInput2D& operator=(FiniteDifferenceInput2D&& rhs) noexcept = default;
	};
}