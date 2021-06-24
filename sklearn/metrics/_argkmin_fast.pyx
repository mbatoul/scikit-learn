# cython: language_level=3
# cython: cdivision=True
# cython: boundscheck=False
# cython: wraparound=False
# cython: profile=False
# cython: linetrace=False
# cython: binding=False
# distutils: define_macros=CYTHON_TRACE_NOGIL=0

import numpy as np
cimport numpy as np

from libc.math cimport floor, sqrt
from libc.stdlib cimport free, malloc

from cython cimport floating
from cython.parallel cimport parallel, prange

DEF CHUNK_SIZE = 256  # number of vectors

DEF MIN_CHUNK_SAMPLES = 20

DEF FLOAT_INF = 1e36

from ..utils._cython_blas cimport (
  BLAS_Order,
  BLAS_Trans,
  ColMajor,
  NoTrans,
  RowMajor,
  Trans,
  _gemm,
)

from ..utils._heap cimport _simultaneous_sort, _push
from ..utils._openmp_helpers import _openmp_effective_n_threads
from ..utils._typedefs cimport ITYPE_t
from ..utils._typedefs import ITYPE

ctypedef floating (*dist_func_ptr)(
    floating[:, ::1],
    int,
    floating[:, ::1],
    int,
    integral,
)


### argkmin helpers

cdef void _argkmin_on_chunk(
    floating[:, ::1] X_c,                  # IN
    floating[:, ::1] Y_c,                  # IN
    floating[::1] Y_sq_norms,              # IN
    floating *dist_middle_terms,           # IN
    floating *heaps_red_distances,         # IN/OUT
    ITYPE_t *heaps_indices,               # IN/OUT
    ITYPE_t k,                            # IN
    # ID of the first element of Y_c
    ITYPE_t Y_idx_offset,
) nogil:
    """
    Critical part of the computation of pairwise distances.

    "Fast Squared Euclidean" distances strategy relying
    on the gemm-trick.
    """
    cdef:
        ITYPE_t i, j
    # Instead of computing the full pairwise squared distances matrix,
    # ||X_c - Y_c||² = ||X_c||² - 2 X_c.Y_c^T + ||Y_c||²,
    # we only need to store the - 2 X_c.Y_c^T + ||Y_c||²
    # term since the argmin for a given sample X_c^{i} does not depend on
    # ||X_c^{i}||²

    # Careful: LDA, LDB and LDC are given for F-ordered arrays.
    # Here, we use their counterpart values as indicated in the documentation.
    # See the documentation of parameters here:
    # https://www.netlib.org/lapack/explore-html/db/dc9/group__single__blas__level3_gafe51bacb54592ff5de056acabd83c260.html
    #
    # dist_middle_terms = -2 * X_c.dot(Y_c.T)
    _gemm(RowMajor, NoTrans, Trans,
          X_c.shape[0], Y_c.shape[0], X_c.shape[1],
          -2.0,
          &X_c[0, 0], X_c.shape[1],
          &Y_c[0, 0], X_c.shape[1], 0.0,
          dist_middle_terms, Y_c.shape[0])

    # Computing argmins here
    for i in range(X_c.shape[0]):
        for j in range(Y_c.shape[0]):
            _push(heaps_red_distances + i * k,
                  heaps_indices + i * k,
                  k,
                  # reduced distance: - 2 X_c_i.Y_c_j^T + ||Y_c_j||²
                  dist_middle_terms[i * Y_c.shape[0] + j] + Y_sq_norms[j],
                  j + Y_idx_offset)



cdef int _argkmin_on_X(
    floating[:, ::1] X,                       # IN
    floating[:, ::1] Y,                       # IN
    floating[::1] Y_sq_norms,                 # IN
    ITYPE_t chunk_size,                      # IN
    ITYPE_t effective_n_threads,             # IN
    ITYPE_t[:, ::1] argkmin_indices,         # OUT
    floating[:, ::1] argkmin_red_distances,   # OUT
) nogil:
    """Computes the argkmin of each vector (row) of X on Y
    by parallelising computation on chunks of X.
    """
    cdef:
        ITYPE_t k = argkmin_indices.shape[1]
        ITYPE_t d = X.shape[1]
        ITYPE_t sf = sizeof(floating)
        ITYPE_t si = sizeof(ITYPE_t)
        ITYPE_t n_samples_chunk = max(MIN_CHUNK_SAMPLES, chunk_size)

        ITYPE_t n_train = Y.shape[0]
        ITYPE_t Y_n_samples_chunk = min(n_train, n_samples_chunk)
        ITYPE_t Y_n_full_chunks = n_train / Y_n_samples_chunk
        ITYPE_t Y_n_samples_rem = n_train % Y_n_samples_chunk

        ITYPE_t n_test = X.shape[0]
        ITYPE_t X_n_samples_chunk = min(n_test, n_samples_chunk)
        ITYPE_t X_n_full_chunks = n_test // X_n_samples_chunk
        ITYPE_t X_n_samples_rem = n_test % X_n_samples_chunk

        # Counting remainder chunk in total number of chunks
        ITYPE_t Y_n_chunks = Y_n_full_chunks + (
            n_train != (Y_n_full_chunks * Y_n_samples_chunk)
        )

        ITYPE_t X_n_chunks = X_n_full_chunks + (
            n_test != (X_n_full_chunks * X_n_samples_chunk)
        )

        ITYPE_t num_threads = min(Y_n_chunks, effective_n_threads)

        ITYPE_t Y_start, Y_end, X_start, X_end
        ITYPE_t X_chunk_idx, Y_chunk_idx, idx, jdx

        floating *dist_middle_terms_chunks
        floating *heaps_red_distances_chunks


    with nogil, parallel(num_threads=num_threads):
        # Thread local buffers

        # Temporary buffer for the -2 * X_c.dot(Y_c.T) term
        dist_middle_terms_chunks = <floating*> malloc(Y_n_samples_chunk * X_n_samples_chunk * sf)
        heaps_red_distances_chunks = <floating*> malloc(X_n_samples_chunk * k * sf)

        for X_chunk_idx in prange(X_n_chunks, schedule='static'):
            # We reset the heap between X chunks (memset isn't suitable here)
            for idx in range(X_n_samples_chunk * k):
                heaps_red_distances_chunks[idx] = FLOAT_INF

            X_start = X_chunk_idx * X_n_samples_chunk
            if X_chunk_idx == X_n_chunks - 1 and X_n_samples_rem > 0:
                X_end = X_start + X_n_samples_rem
            else:
                X_end = X_start + X_n_samples_chunk

            for Y_chunk_idx in range(Y_n_chunks):
                Y_start = Y_chunk_idx * Y_n_samples_chunk
                if Y_chunk_idx == Y_n_chunks - 1 and Y_n_samples_rem > 0:
                    Y_end = Y_start + Y_n_samples_rem
                else:
                    Y_end = Y_start + Y_n_samples_chunk

                _argkmin_on_chunk(
                    X[X_start:X_end, :],
                    Y[Y_start:Y_end, :],
                    Y_sq_norms[Y_start:Y_end],
                    dist_middle_terms_chunks,
                    heaps_red_distances_chunks,
                    &argkmin_indices[X_start, 0],
                    k,
                    Y_start
                )

            # Sorting indices so that the closests' come first.
            for idx in range(X_end - X_start):
                _simultaneous_sort(
                    heaps_red_distances_chunks + idx * k,
                    &argkmin_indices[X_start + idx, 0],
                    k
                )

        # end: for X_chunk_idx
        free(dist_middle_terms_chunks)
        free(heaps_red_distances_chunks)

    # end: with nogil, parallel
    return X_n_chunks


cdef int _argkmin_on_Y(
    floating[:, ::1] X,                       # IN
    floating[:, ::1] Y,                       # IN
    floating[::1] Y_sq_norms,                 # IN
    ITYPE_t chunk_size,                      # IN
    ITYPE_t effective_n_threads,             # IN
    ITYPE_t[:, ::1] argkmin_indices,         # OUT
    floating[:, ::1] argkmin_red_distances,   # OUT
) nogil:
    """Computes the argkmin of each vector (row) of X on Y
    by parallelising computation on chunks of Y.

    This parallelisation strategy is more costly (as we need
    extra heaps and synchronisation), yet it is useful in
    most contexts.
    """
    cdef:
        ITYPE_t k = argkmin_indices.shape[1]
        ITYPE_t d = X.shape[1]
        ITYPE_t sf = sizeof(floating)
        ITYPE_t si = sizeof(ITYPE_t)
        ITYPE_t n_samples_chunk = max(MIN_CHUNK_SAMPLES, chunk_size)

        ITYPE_t n_train = Y.shape[0]
        ITYPE_t Y_n_samples_chunk = min(n_train, n_samples_chunk)
        ITYPE_t Y_n_full_chunks = n_train / Y_n_samples_chunk
        ITYPE_t Y_n_samples_rem = n_train % Y_n_samples_chunk

        ITYPE_t n_test = X.shape[0]
        ITYPE_t X_n_samples_chunk = min(n_test, n_samples_chunk)
        ITYPE_t X_n_full_chunks = n_test // X_n_samples_chunk
        ITYPE_t X_n_samples_rem = n_test % X_n_samples_chunk

        # Counting remainder chunk in total number of chunks
        ITYPE_t Y_n_chunks = Y_n_full_chunks + (
            n_train != (Y_n_full_chunks * Y_n_samples_chunk)
        )

        ITYPE_t X_n_chunks = X_n_full_chunks + (
            n_test != (X_n_full_chunks * X_n_samples_chunk)
        )

        ITYPE_t num_threads = min(Y_n_chunks, effective_n_threads)

        ITYPE_t Y_start, Y_end, X_start, X_end
        ITYPE_t X_chunk_idx, Y_chunk_idx, idx, jdx

        floating *dist_middle_terms_chunks
        floating *heaps_red_distances_chunks

        # As chunks of X are shared across threads, so must their
        # heaps. To solve this, each thread has its own locals
        # heaps which are then synchronised back in the main ones.
        ITYPE_t *heaps_indices_chunks

    for X_chunk_idx in range(X_n_chunks):
        X_start = X_chunk_idx * X_n_samples_chunk
        if X_chunk_idx == X_n_chunks - 1 and X_n_samples_rem > 0:
            X_end = X_start + X_n_samples_rem
        else:
            X_end = X_start + X_n_samples_chunk

        with nogil, parallel(num_threads=num_threads):
            # Thread local buffers

            # Temporary buffer for the -2 * X_c.dot(Y_c.T) term
            dist_middle_terms_chunks = <floating*> malloc(
                Y_n_samples_chunk * X_n_samples_chunk * sf)
            heaps_red_distances_chunks = <floating*> malloc(
                X_n_samples_chunk * k * sf)
            heaps_indices_chunks = <ITYPE_t*> malloc(
                X_n_samples_chunk * k * sf)

            # Initialising heaps (memset can't be used here)
            for idx in range(X_n_samples_chunk * k):
                heaps_red_distances_chunks[idx] = FLOAT_INF
                heaps_indices_chunks[idx] = -1

            for Y_chunk_idx in prange(Y_n_chunks, schedule='static'):
                Y_start = Y_chunk_idx * Y_n_samples_chunk
                if Y_chunk_idx == Y_n_chunks - 1 \
                    and Y_n_samples_rem > 0:
                    Y_end = Y_start + Y_n_samples_rem
                else:
                    Y_end = Y_start + Y_n_samples_chunk

                _argkmin_on_chunk(
                    X[X_start:X_end, :],
                    Y[Y_start:Y_end, :],
                    Y_sq_norms[Y_start:Y_end],
                    dist_middle_terms_chunks,
                    heaps_red_distances_chunks,
                    heaps_indices_chunks,
                    k,
                    Y_start,
                )

            # end: for Y_chunk_idx
            with gil:
                # Synchronising the thread local heaps
                # with the main heaps
                for idx in range(X_end - X_start):
                    for jdx in range(k):
                        _push(
                            &argkmin_red_distances[X_start + idx, 0],
                            &argkmin_indices[X_start + idx, 0],
                            k,
                            heaps_red_distances_chunks[idx * k + jdx],
                            heaps_indices_chunks[idx * k + jdx],
                        )

            free(dist_middle_terms_chunks)
            free(heaps_red_distances_chunks)
            free(heaps_indices_chunks)

        # end: with nogil, parallel
        # Sorting indices of the argkmin for each query vector of X
        for idx in prange(n_test,schedule='static',
                          nogil=True, num_threads=num_threads):
            _simultaneous_sort(
                &argkmin_red_distances[idx, 0],
                &argkmin_indices[idx, 0],
                k,
            )
        # end: prange

    # end: for X_chunk_idx
    return Y_n_chunks

cdef inline floating _euclidean_dist(
    floating[:, ::1] X,
    floating[:, ::1] Y,
    ITYPE_t i,
    ITYPE_t j,
) nogil:
    cdef:
        floating dist = 0
        ITYPE_t k
        ITYPE_t upper_unrolled_idx = (X.shape[1] // 4) * 4

    # Unrolling loop to help with vectorisation
    for k in range(0, upper_unrolled_idx, 4):
        dist += (X[i, k] - Y[j, k]) * (X[i, k] - Y[j, k])
        dist += (X[i, k + 1] - Y[j, k + 1]) * (X[i, k + 1] - Y[j, k + 1])
        dist += (X[i, k + 2] - Y[j, k + 2]) * (X[i, k + 2] - Y[j, k + 2])
        dist += (X[i, k + 3] - Y[j, k + 3]) * (X[i, k + 3] - Y[j, k + 3])

    for k in range(upper_unrolled_idx, X.shape[1]):
        dist += (X[i, k] - Y[j, k]) * (X[i, k] - Y[j, k])

    return sqrt(dist)

cdef int _exact_euclidean_dist(
    floating[:, ::1] X,                  # IN
    floating[:, ::1] Y,                  # IN
    ITYPE_t[:, ::1] Y_indices,          # IN
    ITYPE_t effective_n_threads,        # IN
    floating[:, ::1] distances,          # OUT
) nogil:
    """
    Compute exact pairwise euclidean distances in parallel.

    The pairwise distances considered are X vectors
    and a subset of Y given for each row if X given in
    Y_indices.

    Notes: the body of this function could have been inlined,
    but we use a function to have a cdef nogil context.
    """
    cdef:
        ITYPE_t i, k

    for i in prange(X.shape[0], schedule='static',
                    nogil=True, num_threads=effective_n_threads):
        for k in range(Y_indices.shape[1]):
            distances[i, k] = _euclidean_dist(X, Y, i,
                                              Y_indices[i, k])


# Python interface

def _argkmin(
    floating[:, ::1] X,
    floating[:, ::1] Y,
    ITYPE_t k,
    ITYPE_t chunk_size = CHUNK_SIZE,
    str strategy = "auto",
    bint return_distance = False,
):
    """Computes the argkmin of vectors (rows) of X on Y for
    the euclidean distance.

    The implementation is parallelised on chunks whose size can
    be set using ``chunk_size``.

    Parameters
    ----------
    X: ndarray of shape (n, d)
        Rows represent vectors

    Y: ndarray of shape (m, d)
        Rows represent vectors

    chunk_size: int
        The number of vectors per chunk.

    strategy: str, {'auto', 'chunk_on_X', 'chunk_on_Y'}
        The chunking strategy defining which dataset
        parallelisation are made on.

         - 'chunk_on_X' is embarassingly parallel but
        is less used in practice.
         - 'chunk_on_Y' comes with synchronisation but
        is more useful in practice.
         -'auto' relies on a simple heuristic to choose
        between 'chunk_on_X' and 'chunk_on_Y'.

    return_distance: boolean
        Return distances between each X vectory and its
        argkmin if set to True.

    Returns
    -------
    distances: ndarray of shape (n, k)
        Distances between each X vector and its argkmin
        in Y. Only returned if ``return_distance=True``.

    indices: ndarray of shape (n, k)
        Indices of each X vector argkmin in Y.
    """
    int_dtype = np.intp
    float_dtype = np.float32 if floating is float else np.float64
    cdef:
        ITYPE_t[:, ::1] argkmin_indices = np.full((X.shape[0], k), 0,
                                               dtype=ITYPE)
        floating[:, ::1] argkmin_distances = np.full((X.shape[0], k),
                                                  FLOAT_INF,
                                                  dtype=float_dtype)
        floating[::1] Y_sq_norms = np.einsum('ij,ij->i', Y, Y)
        ITYPE_t effective_n_threads = _openmp_effective_n_threads()

    if strategy == 'auto':
        # This is a simple heuristic whose constant for the
        # comparison has been chosen based on experiments.
        if 4 * chunk_size * effective_n_threads < X.shape[0]:
            strategy = 'chunk_on_X'
        else:
            strategy = 'chunk_on_Y'

    if strategy == 'chunk_on_Y':
        _argkmin_on_Y(
            X, Y, Y_sq_norms,
            chunk_size, effective_n_threads,
            argkmin_indices, argkmin_distances
        )
    elif strategy == 'chunk_on_X':
        _argkmin_on_X(
            X, Y, Y_sq_norms,
            chunk_size, effective_n_threads,
            argkmin_indices, argkmin_distances
        )
    else:
        raise RuntimeError(f"strategy '{strategy}' not supported.")

    if return_distance:
        # We need to recompute distances because we relied on
        # reduced distances using _gemm, which are missing a
        # term for squarred norms and which are not the most
        # precise (catastrophic cancellation might have happened).
        _exact_euclidean_dist(X, Y, argkmin_indices,
                              effective_n_threads,
                              argkmin_distances)
        return (np.asarray(argkmin_distances),
                np.asarray(argkmin_indices))

    return np.asarray(argkmin_indices)
