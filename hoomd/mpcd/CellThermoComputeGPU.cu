// Copyright (c) 2009-2017 The Regents of the University of Michigan
// This file is part of the HOOMD-blue project, released under the BSD 3-Clause License.

// Maintainer: mphoward

/*!
 * \file mpcd/CellThermoComputeGPU.cu
 * \brief Explicitly instantiates reduction operators and declares kernel drivers
 *        for mpcd::CellThermoComputeGPU.
 */

#include "CellThermoComputeGPU.cuh"
#include "CellThermoTypes.h"

#include "CellCommunicator.cuh"
#include "ReductionOperators.h"

#include "hoomd/extern/cub/cub/device/device_reduce.cuh"

namespace mpcd
{
namespace gpu
{
namespace kernel
{
//! Begins the cell thermo compute by summing cell quantities
/*!
 * \param d_cell_vel Velocity and mass per cell (output)
 * \param d_cell_energy Energy, temperature, number of particles per cell (output)
 * \param d_cell_np Number of particles per cell
 * \param d_cell_list MPCD cell list
 * \param cli Indexer into the cell list
 * \param d_vel MPCD particle velocities
 * \param N_mpcd Number of MPCD particles
 * \param mpcd_mass Mass of MPCD particle
 * \param d_embed_vel Embedded particle velocity
 * \param d_embed_cell Embedded particle cells
 *
 * \b Implementation details:
 * Using one thread per cell, the cell properties are accumulated into \a d_cell_vel
 * and \a d_cell_energy.
 *
 * \todo The cell accumulation could have wider parallelism by using multiple
 *       threads in a strided access pattern to compute the cell properties.
 */
__global__ void begin_cell_thermo(Scalar4 *d_cell_vel,
                                  Scalar3 *d_cell_energy,
                                  const unsigned int *d_cell_np,
                                  const unsigned int *d_cell_list,
                                  const Index2D cli,
                                  const Scalar4 *d_vel,
                                  const unsigned int N_mpcd,
                                  const Scalar mpcd_mass,
                                  const Scalar4 *d_embed_vel,
                                  const unsigned int *d_embed_cell)
    {
    // one thread per cell
    unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= cli.getH())
        return;

    const unsigned int np = d_cell_np[idx];
    double4 momentum = make_double4(0.0, 0.0, 0.0, 0.0);
    double ke(0.0);

    // this could be unrolled with multiple threads per cell
    for (unsigned int offset = 0; offset < np; ++offset)
        {
        // Load particle data
        const unsigned int cur_p = d_cell_list[cli(offset, idx)];
        double3 vel_i;
        double mass_i;
        if (cur_p < N_mpcd)
            {
            Scalar4 vel_cell = d_vel[cur_p];
            vel_i = make_double3(vel_cell.x, vel_cell.y, vel_cell.z);
            mass_i = mpcd_mass;
            }
        else
            {
            Scalar4 vel_m = d_embed_vel[d_embed_cell[cur_p - N_mpcd]];
            vel_i = make_double3(vel_m.x, vel_m.y, vel_m.z);
            mass_i = vel_m.w;
            }

        // add momentum
        momentum.x += mass_i * vel_i.x;
        momentum.y += mass_i * vel_i.y;
        momentum.z += mass_i * vel_i.z;
        momentum.w += mass_i;

        // also compute ke of the particle
        ke += (double)(0.5) * mass_i * (vel_i.x * vel_i.x + vel_i.y * vel_i.y + vel_i.z * vel_i.z);
        }

    d_cell_vel[idx] = momentum;
    d_cell_energy[idx] = make_scalar3(ke, 0.0, __int_as_scalar(np));
    }

//! Finalizes the cell thermo compute by properly averaging cell quantities
/*!
 * \param d_cell_vel Cell velocity and masses
 * \param d_cell_energy Cell energy and temperature
 * \param Ncell Number of cells
 * \param n_dimensions Number of dimensions in system
 *
 * \b Implementation details:
 * Using one thread per cell, the properties are averaged by mass, number of particles,
 * etc. The temperature is computed from the cell kinetic energy.
 */
__global__ void end_cell_thermo(Scalar4 *d_cell_vel,
                                Scalar3 *d_cell_energy,
                                const unsigned int Ncell,
                                const unsigned int n_dimensions)
    {
    // one thread per cell
    unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= Ncell)
        return;

    // average cell properties if the cell has mass
    const Scalar4 cell_vel = d_cell_vel[idx];
    Scalar3 vel_cm = make_scalar3(cell_vel.x, cell_vel.y, cell_vel.z);
    const Scalar mass = cell_vel.w;

    const Scalar3 cell_energy = d_cell_energy[idx];
    const Scalar ke = cell_energy.x;
    Scalar temp(0.0);
    const unsigned int np = __scalar_as_int(cell_energy.z);

    if (mass > 0.)
        {
        // average velocity is only defined when there is some mass in the cell
        vel_cm /= mass;

        // temperature is only defined for 2 or more particles
        if (np > 1)
            {
            const Scalar ke_cm = Scalar(0.5) * mass * dot(vel_cm, vel_cm);
            temp = Scalar(2.) * (ke - ke_cm) / Scalar(n_dimensions * (np-1));
            }
        }

    d_cell_vel[idx] = make_scalar4(vel_cm.x, vel_cm.y, vel_cm.z, mass);
    d_cell_energy[idx] = make_scalar3(ke, temp, __int_as_scalar(np));
    }

/*!
 * \param d_tmp_thermo Temporary cell packed thermo element
 * \param d_cell_vel Cell velocity to reduce
 * \param d_cell_energy Cell energy to reduce
 * \param tmp_ci Temporary cell indexer for cells undergoing reduction
 * \param ci Cell indexer Regular cell list indexer
 *
 * \b Implementation details:
 * Using one thread per \a temporary cell, the cell properties are normalized
 * in a way suitable for reduction of net properties, e.g. the cell velocities
 * are converted to momentum. The temperature is set to the cell energy, and a
 * flag is set to 1 or 0 to indicate whether this cell has an energy that should
 * be used in averaging the total temperature.
 */
__global__ void stage_net_cell_thermo(mpcd::detail::cell_thermo_element *d_tmp_thermo,
                                      const Scalar4 *d_cell_vel,
                                      const Scalar3 *d_cell_energy,
                                      const Index3D tmp_ci,
                                      const Index3D ci)
    {
    // one thread per cell
    unsigned int tmp_idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (tmp_idx >= tmp_ci.getNumElements())
        return;

    // use the temporary cell indexer to map to a cell, then use the real cell indexer to
    // get the read index
    uint3 cell = tmp_ci.getTriple(tmp_idx);
    const unsigned int idx = ci(cell.x, cell.y, cell.z);

    const Scalar4 vel_mass = d_cell_vel[idx];
    const double3 vel = make_double3(vel_mass.x, vel_mass.y, vel_mass.z);
    const double mass = vel_mass.w;

    mpcd::detail::cell_thermo_element thermo;
    thermo.momentum = make_double3(mass * vel.x,
                                   mass * vel.y,
                                   mass * vel.z);

    const Scalar3 cell_energy = d_cell_energy[idx];
    thermo.energy = cell_energy.x;
    if (__scalar_as_int(cell_energy.z) > 1)
        {
        thermo.temperature = cell_energy.y;
        thermo.flag = 1;
        }
    else
        {
        thermo.temperature = 0.0;
        thermo.flag = 0;
        }

    d_tmp_thermo[tmp_idx] = thermo;
    }

} // end namespace kernel

/*
 * \param d_cell_vel Velocity and mass per cell (output)
 * \param d_cell_energy Energy, temperature, number of particles per cell (output)
 * \param d_cell_np Number of particles per cell
 * \param d_cell_list MPCD cell list
 * \param cli Indexer into the cell list
 * \param d_vel MPCD particle velocities
 * \param N_mpcd Number of MPCD particles
 * \param mpcd_mass Mass of MPCD particle
 * \param d_embed_vel Embedded particle velocity
 * \param d_embed_cell Embedded particle cells
 * \param block_size Number of threads per block
 *
 * \returns cudaSuccess on completion
 *
 * \sa mpcd::gpu::kernel::begin_cell_thermo
 */
cudaError_t begin_cell_thermo(Scalar4 *d_cell_vel,
                              Scalar3 *d_cell_energy,
                              const unsigned int *d_cell_np,
                              const unsigned int *d_cell_list,
                              const Index2D& cli,
                              const Scalar4 *d_vel,
                              const unsigned int N_mpcd,
                              const Scalar mpcd_mass,
                              const Scalar4 *d_embed_vel,
                              const unsigned int *d_embed_cell,
                              const unsigned int block_size)
    {
    static unsigned int max_block_size = UINT_MAX;
    if (max_block_size == UINT_MAX)
        {
        cudaFuncAttributes attr;
        cudaFuncGetAttributes(&attr, (const void*)mpcd::gpu::kernel::begin_cell_thermo);
        max_block_size = attr.maxThreadsPerBlock;
        }

    unsigned int run_block_size = min(block_size, max_block_size);
    dim3 grid(cli.getH() / run_block_size + 1);
    mpcd::gpu::kernel::begin_cell_thermo<<<grid, run_block_size>>>(d_cell_vel,
                                                                   d_cell_energy,
                                                                   d_cell_np,
                                                                   d_cell_list,
                                                                   cli,
                                                                   d_vel,
                                                                   N_mpcd,
                                                                   mpcd_mass,
                                                                   d_embed_vel,
                                                                   d_embed_cell);

    return cudaSuccess;
    }

/*!
 * \param d_cell_vel Cell velocity and masses
 * \param d_cell_energy Cell energy and temperature
 * \param Ncell Number of cells
 * \param n_dimensions Number of dimensions in system
 *
 * \returns cudaSuccess on completion
 *
 * \sa mpcd::gpu::kernel::end_cell_thermo
 */
cudaError_t end_cell_thermo(Scalar4 *d_cell_vel,
                            Scalar3 *d_cell_energy,
                            const unsigned int Ncell,
                            const unsigned int n_dimensions,
                            const unsigned int block_size)
    {
    static unsigned int max_block_size = UINT_MAX;
    if (max_block_size == UINT_MAX)
        {
        cudaFuncAttributes attr;
        cudaFuncGetAttributes(&attr, (const void*)mpcd::gpu::kernel::end_cell_thermo);
        max_block_size = attr.maxThreadsPerBlock;
        }

    unsigned int run_block_size = min(block_size, max_block_size);
    dim3 grid(Ncell / run_block_size + 1);
    mpcd::gpu::kernel::end_cell_thermo<<<grid, run_block_size>>>(d_cell_vel,
                                                                 d_cell_energy,
                                                                 Ncell,
                                                                 n_dimensions);

    return cudaSuccess;
    }

/*!
 * \param d_tmp_thermo Temporary cell packed thermo element
 * \param d_cell_vel Cell velocity to reduce
 * \param d_cell_energy Cell energy to reduce
 * \param tmp_ci Temporary cell indexer for cells undergoing reduction
 * \param ci Cell indexer Regular cell list indexer
 * \param block_size Number of threads per block
 *
 * \returns cudaSuccess on completion
 *
 * \sa mpcd::gpu::kernel::stage_net_cell_thermo
 */
cudaError_t stage_net_cell_thermo(mpcd::detail::cell_thermo_element *d_tmp_thermo,
                                  const Scalar4 *d_cell_vel,
                                  const Scalar3 *d_cell_energy,
                                  const Index3D& tmp_ci,
                                  const Index3D& ci,
                                  const unsigned int block_size)
    {
    static unsigned int max_block_size = UINT_MAX;
    if (max_block_size == UINT_MAX)
        {
        cudaFuncAttributes attr;
        cudaFuncGetAttributes(&attr, (const void*)mpcd::gpu::kernel::stage_net_cell_thermo);
        max_block_size = attr.maxThreadsPerBlock;
        }

    unsigned int run_block_size = min(block_size, max_block_size);
    dim3 grid(tmp_ci.getNumElements() / run_block_size + 1);
    mpcd::gpu::kernel::stage_net_cell_thermo<<<grid, run_block_size>>>(d_tmp_thermo,
                                                                       d_cell_vel,
                                                                       d_cell_energy,
                                                                       tmp_ci,
                                                                       ci);
    return cudaSuccess;
    }

/*!
 * \param d_reduced Cell thermo properties reduced across all cells (output on second call)
 * \param d_tmp Temporary storage for reduction (output on first call)
 * \param tmp_bytes Number of bytes allocated for temporary storage (output on first call)
 * \param d_tmp_thermo Cell thermo properties to reduce
 * \param Ncell The number of cells to reduce across
 *
 * \returns cudaSuccess on completion
 *
 * \b Implementation details:
 * CUB DeviceReduce is used to perform the reduction. Hence, this function requires
 * two calls to perform the reduction. The first call sizes the temporary storage,
 * which is returned in \a d_tmp and \a tmp_bytes. The caller must then allocate
 * the required bytes, and call the function a second time. This performs the
 * reducetion and returns the result in \a d_reduced.
 */
cudaError_t reduce_net_cell_thermo(mpcd::detail::cell_thermo_element *d_reduced,
                                   void *d_tmp,
                                   size_t& tmp_bytes,
                                   const mpcd::detail::cell_thermo_element *d_tmp_thermo,
                                   const unsigned int Ncell)
    {
    cub::DeviceReduce::Sum(d_tmp, tmp_bytes, d_tmp_thermo, d_reduced, Ncell);
    return cudaSuccess;
    }

//! Explicit template instantiation of pack for cell velocity
template cudaError_t pack_cell_buffer(typename mpcd::detail::CellVelocityPackOp::element *d_left_buf,
                                      typename mpcd::detail::CellVelocityPackOp::element *d_right_buf,
                                      const Index3D& left_idx,
                                      const Index3D& right_idx,
                                      const uint3& right_offset,
                                      const Scalar4 *d_props,
                                      mpcd::detail::CellVelocityPackOp pack_op,
                                      const Index3D& ci,
                                      unsigned int block_size);

//! Explicit template instantiation of pack for cell energy
template cudaError_t pack_cell_buffer(typename mpcd::detail::CellEnergyPackOp::element *d_left_buf,
                                      typename mpcd::detail::CellEnergyPackOp::element *d_right_buf,
                                      const Index3D& left_idx,
                                      const Index3D& right_idx,
                                      const uint3& right_offset,
                                      const Scalar3 *d_props,
                                      mpcd::detail::CellEnergyPackOp pack_op,
                                      const Index3D& ci,
                                      unsigned int block_size);

//! Explicit template instantiation of unpack for cell velocity
template cudaError_t unpack_cell_buffer(Scalar4 *d_props,
                                        mpcd::detail::CellVelocityPackOp pack_op,
                                        const Index3D& ci,
                                        const typename mpcd::detail::CellVelocityPackOp::element *d_left_buf,
                                        const typename mpcd::detail::CellVelocityPackOp::element *d_right_buf,
                                        const Index3D& left_idx,
                                        const Index3D& right_idx,
                                        const uint3& right_offset,
                                        const unsigned int block_size);

//! Explicit template instantiation of unpack for cell energy
template cudaError_t unpack_cell_buffer(Scalar3 *d_props,
                                        mpcd::detail::CellEnergyPackOp pack_op,
                                        const Index3D& ci,
                                        const typename mpcd::detail::CellEnergyPackOp::element *d_left_buf,
                                        const typename mpcd::detail::CellEnergyPackOp::element *d_right_buf,
                                        const Index3D& left_idx,
                                        const Index3D& right_idx,
                                        const uint3& right_offset,
                                        const unsigned int block_size);

} // end namespace gpu
} // end namespace mpcd
