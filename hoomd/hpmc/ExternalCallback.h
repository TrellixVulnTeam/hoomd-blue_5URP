// Copyright (c) 2009-2017 The Regents of the University of Michigan
// This file is part of the HOOMD-blue project, released under the BSD 3-Clause License.

#ifndef _EXTERNAL_CALLBACK_H
#define _EXTERNAL_CALLBACK_H_

/*! \file ExternalCallback.h
    \brief Declaration of ExternalCallback base class
*/

#include "hoomd/Compute.h"
#include "hoomd/extern/saruprng.h"
#include "hoomd/VectorMath.h"
#include "hoomd/SnapshotSystemData.h"

#include "ExternalField.h"

#ifndef NVCC
#include <hoomd/extern/pybind/include/pybind11/pybind11.h>
#endif

namespace hpmc
{

template< class Shape>
class ExternalCallback : public ExternalFieldMono<Shape>
    {
    public:
        ExternalCallback(std::shared_ptr<SystemDefinition> sysdef,
                         pybind11::object energy_function)
            : ExternalFieldMono<Shape>(sysdef), callback(energy_function)
            { }

        ~ExternalCallback() { }

        //! Compute Boltzmann weight exp(-U) of current configuration
        Scalar calculateBoltzmannWeight(unsigned int timestep)
            {
            auto snap = takeSnapshot();
            Scalar energy = getEnergy(snap);
            return exp(-energy);
            }

        //! Compute Boltzmann factor exp(-DeltaU) of a trial box resize
        /*! \param position_old_arg Old (local) positions
            \param orientation_old_arg Old (local) orientations
            \param box_old_arg Old (global) box
         */
        Scalar calculateBoltzmannFactor(const Scalar4 * const position_old_arg,
                                        const Scalar4 * const orientation_old_arg,
                                        const BoxDim * const box_old_arg
                                        )
            {
            auto snap = takeSnapshot();
            Scalar energy_new = getEnergy(snap);

            // update snapshot with old configuration
            snap->global_box = *box_old_arg;
            unsigned int N = this->m_pdata->getN();
            ArrayHandle<unsigned int> h_tag(this->m_pdata->getTags(), access_location::host, access_mode::read);
            for (unsigned int i = 0; i < N; ++i)
                {
                unsigned int tag = h_tag.data[i];
                auto snap_it = snap->map.find(tag);
                assert (snap_it != snap->map.end());
                unsigned int snap_idx = snap_it->second;
                snap->particle_data.pos[snap_idx] = vec3<Scalar>(position_old_arg[i]);
                snap->particle_data.orientation[snap_idx] = quat<Scalar>(orientation_old_arg[i]);
                }

            Scalar energy_old = getEnergy(snap);

            return exp(-energy_new+energy_old);
            }

        // does nothing
        void compute(unsigned int timestep) { }

        //! Return true if a particle trial move is accepted
        bool accept(const unsigned int& index, const vec3<Scalar>& position_old, const Shape& shape_old, const vec3<Scalar>& position_new, const Shape& shape_new, Saru& rng)
            {
            // calc boltzmann factor from springs
            Scalar boltz = boltzmann(index, position_old, shape_old, position_new, shape_new);
            bool reject = false;
            if(rng.s(Scalar(0.0),Scalar(1.0)) < boltz)
                reject = false;
            else
                reject = true;

            return !reject;
            }

        Scalar boltzmann(const unsigned int& index, const vec3<Scalar>& position_old,
            const Shape& shape_old, const vec3<Scalar>& position_new, const Shape& shape_new)
            {
            // find index in snapshot
            unsigned int tag;
                {
                ArrayHandle<unsigned int> h_tag(this->m_pdata->getTags(), access_location::host, access_mode::read);
                tag = h_tag.data[index];
                }

            auto snap = takeSnapshot();
            auto snap_it = snap->map.find(tag);
            assert (snap_it != snap->map.end());
            unsigned int snap_idx = snap_it->second;

            // update snapshot with old configuration
            snap->particle_data.pos[snap_idx] = position_old;
            snap->particle_data.orientation[snap_idx] = shape_old.orientation;
            Scalar energy_old = getEnergy(snap);

            // update snapshot with new configruation
            snap->particle_data.pos[snap_idx] = position_new;
            snap->particle_data.orientation[snap_idx] = shape_new.orientation;
            Scalar energy_new = getEnergy(snap);

            return exp(-energy_new+energy_old);
            }

    protected:

        // Take a snapshot of the particle data (only)
        std::shared_ptr<SnapshotSystemData<Scalar> > takeSnapshot()
            {
            return this->m_sysdef->template takeSnapshot<Scalar>(true);
            }

        Scalar getEnergy(std::shared_ptr<SnapshotSystemData<Scalar> > snap)
            {
            Scalar e = 0.0;
            if (callback != pybind11::none())
                {
                pybind11::object rv = callback(snap);
                if (rv != pybind11::none())
                    {
                    e = pybind11::cast<Scalar>(rv);
                    }
                }
            return e;
            }

    private:
        pybind11::object callback; //! The python callback
    };

template<class Shape>
void export_ExternalCallback(pybind11::module& m, const std::string& name)
    {
    pybind11::class_<ExternalCallback<Shape>, std::shared_ptr< ExternalCallback<Shape> > >(m, name.c_str(), pybind11::base< ExternalFieldMono<Shape> >())
    .def(pybind11::init< std::shared_ptr<SystemDefinition>, pybind11::object>())
    ;
    }

} // namespace hpmc

#endif // _EXTERNAL_FIELD_LATTICE_H_
