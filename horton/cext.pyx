# -*- coding: utf-8 -*-
# Horton is a development platform for electronic structure methods.
# Copyright (C) 2011-2013 Toon Verstraelen <Toon.Verstraelen@UGent.be>
#
# This file is part of Horton.
#
# Horton is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 3
# of the License, or (at your option) any later version.
#
# Horton is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, see <http://www.gnu.org/licenses/>
#
#--
#cython: embedsignature=True
'''C++ extensions'''


import numpy as np
cimport numpy as np
np.import_array()

cimport cell
cimport moments
cimport nucpot

__all__ = [
    # cell.cpp
    'Cell', 'smart_wrap',
    # moments.cpp
    'fill_cartesian_polynomials', 'fill_pure_polynomials', 'fill_radial_polynomials',
    # nucpot.cpp
    'compute_grid_nucpot',
]


#
# cell.cpp
#


cdef class Cell:
    '''Representation of periodic boundary conditions.

       0, 1, 2 and 3 dimensional systems are supported. The cell vectors need
       not to be orthogonal.
    '''

    def __cinit__(self, *args, **kwargs):
        self._this = new cell.Cell()

    def __dealloc__(self):
        del self._this

    def __init__(self, np.ndarray[double, ndim=2] rvecs=None):
        '''
           **Arguments:**

           rvecs
                A numpy array with at most three cell vectors, layed out as
                rows in a rank-2 matrix. For non-periodic systems, this array
                must have shape (0,3).
        '''
        self.update_rvecs(rvecs)

    @classmethod
    def from_hdf5(cls, grp, lf):
        if grp['rvecs'].size > 0:
            rvecs = np.array(grp['rvecs'])
            return cls(rvecs)
        else:
            return cls(None)

    def to_hdf5(self, grp):
        grp.create_dataset('rvecs', data=self.rvecs, maxshape=(None,None))

    @classmethod
    def from_parameters(cls, lengths, angles):
        """Construct a cell with the given parameters

           The a vector is always parallel with the x-axis and they point in the
           same direction. The b vector is always in the xy plane and points
           towards the positive y-direction. The c vector points towards the
           positive z-direction.

           The number of elements in the lengths and angles arrays determines
           the number of cell vectors. There are four cases:

           * len(lengths) == 0 and len(angles) == 0: 0 rvecs

           * len(lengths) == 1 and len(angles) == 0: 1 rvecs

           * len(lengths) == 2 and len(angles) == 1: 2 rvecs

           * len(lengths) == 3 and len(angles) == 3: 3 rvecs
        """
        if len(lengths) == 0 and len(angles) != 0:
            raise TypeError('When no lengths are given, no angles are expected.')
        elif len(lengths) == 1 and len(angles) != 0:
            raise TypeError('When one length is given, no angles are expected.')
        elif len(lengths) == 2 and len(angles) != 1:
            raise TypeError('When two lengths are given, one angle is expected.')
        elif len(lengths) == 3 and len(angles) != 3:
            raise TypeError('When three lengths are given, three angles are expected.')
        elif len(lengths) > 3:
            raise ValueError('More than three lengths are given.')

        for length in lengths:
            if length <= 0:
                raise ValueError("The length parameters must be strictly positive.")
        for angle in angles:
            if angle <= 0 or angle >= np.pi:
                raise ValueError("The angle parameters must lie in the range ]0 deg, 180 deg[.")

        if len(lengths) == 0:
            return Cell(None)

        rvecs = np.zeros((len(lengths), 3), float)

        if len(lengths) > 0:
            # first cell vector along x-axis
            rvecs[0, 0] = lengths[0]

        if len(lengths) > 1:
            # second cell vector in x-y plane
            if len(lengths) == 2:
                angle = angles[0]
            else:
                angle = angles[2]
            rvecs[1, 0] = np.cos(angle)*lengths[1]
            rvecs[1, 1] = np.sin(angle)*lengths[1]

        if len(lengths) > 2:
            # Finding the third cell vector is slightly more difficult. :-)
            # It works like this:
            # The dot products of a with c, b with c and c with c are known. the
            # vector a has only an x component, b has no z component. This results
            # in the following equations:
            u_a = lengths[0]*lengths[2]*np.cos(angles[1])
            u_b = lengths[1]*lengths[2]*np.cos(angles[0])
            rvecs[2, 0] = u_a/rvecs[0, 0]
            rvecs[2, 1] = (u_b - rvecs[1, 0]*rvecs[2, 0])/rvecs[1, 1]
            u_c = lengths[2]**2 - rvecs[2, 0]**2 - rvecs[2, 1]**2
            if u_c < 0:
                raise ValueError("The given cell parameters do not correspond to a unit cell.")
            rvecs[2, 2] = np.sqrt(u_c)

        return cls(rvecs)

    def update_rvecs(self, np.ndarray[double, ndim=2] rvecs=None):
        '''Change the cell vectors and recompute the reciprocal cell vectors.

           rvecs
                A numpy array with at most three cell vectors, layed out as
                rows in a rank-2 matrix. For non-periodic systems, this array
                must have shape (0,3).
        '''
        cdef np.ndarray[double, ndim=2] mod_rvecs
        cdef np.ndarray[double, ndim=2] gvecs
        cdef int nvec
        if rvecs is None or rvecs.size == 0:
            mod_rvecs = np.identity(3, float)
            gvecs = mod_rvecs
            nvec = 0
        else:
            if not rvecs.ndim==2 or rvecs.shape[0] > 3 or rvecs.shape[1] != 3:
                raise TypeError('rvecs must be an array with three columns and at most three rows.')
            nvec = len(rvecs)
            Up, Sp, Vt = np.linalg.svd(rvecs, full_matrices=True)
            S = np.ones(3, float)
            S[:nvec] = Sp
            U = np.identity(3, float)
            U[:nvec,:nvec] = Up
            mod_rvecs = np.dot(U*S, Vt)
            mod_rvecs[:nvec] = rvecs
            gvecs = np.dot(U/S, Vt)
        self._this.update(<double*>mod_rvecs.data, <double*>gvecs.data, nvec)

    property nvec:
        '''The number of cell vectors'''
        def __get__(self):
            return self._this.get_nvec()

    property volume:
        '''The generalized volume of the unit cell (length, area or volume)'''
        def __get__(self):
            return self._this.get_volume()

    property rvecs:
        '''The real-space cell vectors, layed out as rows.'''
        def __get__(self):
            cdef np.ndarray[double, ndim=2] result
            result = np.zeros((self.nvec, 3), float)
            self._this.copy_rvecs(<double*>result.data)
            result.setflags(write=False)
            return result

    property gvecs:
        '''The reciporcal-space cell vectors, layed out as rows.'''
        def __get__(self):
            cdef np.ndarray[double, ndim=2] result
            result = np.zeros((self.nvec, 3), float)
            self._this.copy_gvecs(<double*>result.data)
            result.setflags(write=False)
            return result

    property rlengths:
        '''The lengths of the real-space vectors.'''
        def __get__(self):
            cdef np.ndarray[double, ndim=1] result
            result = np.zeros(self.nvec, float)
            self._this.copy_rlengths(<double*>result.data)
            result.setflags(write=False)
            return result

    property glengths:
        '''The lengths of the reciprocal-space vectors.'''
        def __get__(self):
            cdef np.ndarray[double, ndim=1] result
            result = np.zeros(self.nvec, float)
            self._this.copy_glengths(<double*>result.data)
            result.setflags(write=False)
            return result

    property rspacings:
        '''The (orthogonal) spacing between opposite sides of the real-space unit cell.'''
        def __get__(self):
            cdef np.ndarray[double, ndim=1] result
            result = np.zeros(self.nvec, float)
            self._this.copy_rspacings(<double*>result.data)
            result.setflags(write=False)
            return result

    property gspacings:
        '''The (orthogonal) spacing between opposite sides of the reciprocal-space unit cell.'''
        def __get__(self):
            cdef np.ndarray[double, ndim=1] result
            result = np.zeros(self.nvec, float)
            self._this.copy_gspacings(<double*>result.data)
            result.setflags(write=False)
            return result

    def get_rlength(self, int i):
        return self._this.get_rlength(i);

    def get_glength(self, int i):
        return self._this.get_glength(i);

    def get_rspacing(self, int i):
        return self._this.get_rspacing(i);

    def get_gspacing(self, int i):
        return self._this.get_gspacing(i);

    property parameters:
        '''The cell parameters (lengths and angles)'''
        def __get__(self):
            lengths = self.rlengths
            rvecs = self.rvecs
            tmp = np.dot(rvecs, rvecs.T)
            tmp /= lengths
            tmp /= lengths.reshape((-1,1))
            if len(rvecs) < 2:
                cosines = np.array([])
            elif len(rvecs) == 2:
                cosines = np.array([tmp[0,1]])
            else:
                cosines = np.array([tmp[1,2], tmp[2,0], tmp[0,1]])
            angles = np.arccos(np.clip(cosines, -1, 1))
            return lengths, angles

    def mic(self, np.ndarray[double, ndim=1] delta not None):
        '''Apply the minimum image convention to delta in-place'''
        assert delta.flags['C_CONTIGUOUS']
        assert delta.size == 3
        self._this.mic(<double*> delta.data)

    def to_frac(self, np.ndarray[double, ndim=1] cart not None):
        '''Return the corresponding fractional coordinates'''
        assert cart.flags['C_CONTIGUOUS']
        assert cart.size == 3
        cdef np.ndarray[double, ndim=1] result
        result = np.zeros(3, float)
        self._this.to_frac(<double*> cart.data, <double*> result.data)
        return result

    def to_cart(self, np.ndarray[double, ndim=1] frac not None):
        '''Return the corresponding Cartesian coordinates'''
        assert frac.flags['C_CONTIGUOUS']
        assert frac.size == 3
        cdef np.ndarray[double, ndim=1] result
        result = np.zeros(3, float)
        self._this.to_cart(<double*> frac.data, <double*> result.data)
        return result

    def g_lincomb(self, np.ndarray[double, ndim=1] coeffs not None):
        '''Return a linear combination of reciprocal cell vectors'''
        assert coeffs.flags['C_CONTIGUOUS']
        assert coeffs.size == 3
        cdef np.ndarray[double, ndim=1] result
        result = np.zeros(3, float)
        self._this.g_lincomb(<double*> coeffs.data, <double*> result.data)
        return result

    def dot_rvecs(self, np.ndarray[double, ndim=1] cart not None):
        '''Return the corresponding dot product with the rvecs'''
        assert cart.flags['C_CONTIGUOUS']
        assert cart.size == 3
        cdef np.ndarray[double, ndim=1] result
        result = np.zeros(3, float)
        self._this.dot_rvecs(<double*> cart.data, <double*> result.data)
        return result

    def add_rvec(self, np.ndarray[double, ndim=1] delta not None,
                 np.ndarray[long, ndim=1] r not None):
        """Add a linear combination of real cell vectors, ``r``, to ``delta`` in-place"""
        assert delta.flags['C_CONTIGUOUS']
        assert delta.size == 3
        assert r.flags['C_CONTIGUOUS']
        assert r.size == self.nvec
        self._this.add_rvec(<double*> delta.data, <long*> r.data)

    def get_ranges_rcut(self, np.ndarray[double, ndim=1] delta not None, double rcut):
        '''Return the integer ranges for linear combinations of cell vectors.

           **Arguments:**

           delta
                The relative vector between two (interaction) centers

           rcut
                A cutoff radius

           The returned ranges span the linear combination of cell vectors that
           can be added to delta to obtain all periodic images within the cutoff
           sphere centered at the origin.
        '''
        assert delta.flags['C_CONTIGUOUS']
        assert delta.size == 3
        assert rcut >= 0

        cdef np.ndarray[long, ndim=1] ranges_begin = np.zeros(self.nvec, int)
        cdef np.ndarray[long, ndim=1] ranges_end = np.zeros(self.nvec, int)
        self._this.set_ranges_rcut(
            <double*>delta.data, rcut,  <long*>ranges_begin.data,
            <long*>ranges_end.data)
        return ranges_begin, ranges_end

    def select_inside(self, np.ndarray[double, ndim=1] origin not None,
                      np.ndarray[double, ndim=1] center not None,
                      double rcut,
                      np.ndarray[long, ndim=1] ranges_begin not None,
                      np.ndarray[long, ndim=1] ranges_end not None,
                      np.ndarray[long, ndim=1] shape not None,
                      np.ndarray[long, ndim=1] pbc not None,
                      np.ndarray[long, ndim=2] indexes not None):

        assert origin.flags['C_CONTIGUOUS']
        assert origin.size == 3
        assert center.flags['C_CONTIGUOUS']
        assert center.size == 3
        assert rcut >= 0
        assert ranges_begin.flags['C_CONTIGUOUS']
        assert ranges_begin.size == self.nvec
        assert ranges_end.flags['C_CONTIGUOUS']
        assert ranges_end.size == self.nvec
        assert indexes.flags['C_CONTIGUOUS']
        nselect_max = np.product(ranges_end - ranges_begin)
        assert shape.flags['C_CONTIGUOUS']
        assert shape.shape[0] == self.nvec
        assert pbc.flags['C_CONTIGUOUS']
        assert pbc.shape[0] == self.nvec
        assert indexes.shape[0] == nselect_max
        assert indexes.shape[1] == self.nvec

        return self._this.select_inside(
            <double*>origin.data, <double*>center.data, rcut,
            <long*>ranges_begin.data, <long*>ranges_end.data,
            <long*>shape.data, <long*>pbc.data,
            <long*>indexes.data)


def smart_wrap(long i, long shape, long pbc ):
    return cell.smart_wrap(i, shape, pbc)



#
# moments.cpp
#


def fill_cartesian_polynomials(np.ndarray[double, ndim=1] output not None, long lmax):
    '''Fill the output vector with cartesian polynomials

       **Arguments:**

       output
            A double precision numpy array where the first three values are
            x, y and z coordinates.

       lmax
            The maximum angular momentum to compute.

       The polynomials are stored according to the conventions set in
       ``get_cartesian_powers``.

       **Returns:**

       The index of the first element of the array that contains the polynomials
       of the outermost shell.
    '''
    assert output.flags['C_CONTIGUOUS']
    if output.shape[0] < ((lmax+1)*(lmax+2)*(lmax+3))/6-1:
        raise ValueError('The size of the output array is not sufficient to store the polynomials.')
    return moments.fill_cartesian_polynomials(<double*>output.data, lmax)


def fill_pure_polynomials(output not None, long lmax):
    '''Fill the output vector with pure polynomials

       **Arguments:**

       output
            This can either be a double precission Numpy vector or 2D array. In
            the first case, the first three values are z, x, and y coordinates.
            In the second case, the first three columns contain z, x and y
            coordinates.

       lmax
            The maximum angular momentum to compute.

       **Returns:**

       The index of the first element of the array that contains the polynomials
       of the outermost shell.
    '''
    cdef np.ndarray tmp = output
    assert tmp.flags['C_CONTIGUOUS']
    if tmp.ndim == 1:
        if tmp.shape[0] < (lmax+1)**2-1:
            raise ValueError('The size of the output array is not sufficient to store the polynomials.')
        return moments.fill_pure_polynomials(<double*>tmp.data, lmax)
    elif tmp.ndim == 2:
        if tmp.shape[1] < (lmax+1)**2-1:
            raise ValueError('The size of the output array is not sufficient to store the polynomials.')
        return moments.fill_pure_polynomials_array(<double*>tmp.data, lmax, tmp.shape[0], tmp.shape[1])
    else:
        raise NotImplementedError


def fill_radial_polynomials(np.ndarray[double, ndim=1] output not None, long lmax):
    '''Fill the output vector with radial polynomials

       **Arguments:**

       output
            A double precision numpy array where the first element is the radius

       lmax
            The maximum angular momentum to compute.

       All elements after the first will be filled up with increasing powers of
       the first element, up to lmax.
    '''
    assert output.flags['C_CONTIGUOUS']
    if output.shape[0] < lmax:
        raise ValueError('The size of the output array is not sufficient to store the polynomials.')
    moments.fill_radial_polynomials(<double*>output.data, lmax)



#
# nucpot.cpp
#


def compute_grid_nucpot(np.ndarray[long, ndim=1] numbers not None,
                        np.ndarray[double, ndim=2] coordinates not None,
                        np.ndarray[double, ndim=2] points not None,
                        np.ndarray[double, ndim=1] output not None):
        assert numbers.flags['C_CONTIGUOUS']
        cdef long natom = numbers.shape[0]
        assert coordinates.flags['C_CONTIGUOUS']
        assert coordinates.shape[0] == natom
        assert coordinates.shape[1] == 3
        assert output.flags['C_CONTIGUOUS']
        cdef long npoint = output.shape[0]
        assert points.flags['C_CONTIGUOUS']
        assert points.shape[0] == npoint
        assert points.shape[1] == 3
        nucpot.compute_grid_nucpot(
            <long*>numbers.data, <double*>coordinates.data, natom,
            <double*>points.data, <double*>output.data, npoint)
