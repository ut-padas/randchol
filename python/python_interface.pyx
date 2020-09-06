cimport cython
from cpython cimport array
import array
import numpy as np 
cimport numpy as np 
import time
import scipy.sparse
from scipy.sparse import csc_matrix, csr_matrix, triu, linalg
import os
from os.path import dirname, join as pjoin
from libc cimport stdint
import importlib
from libc.stdlib cimport malloc, free
#cimport python_interface as pi
from libc cimport stdint 
import importlib

cdef extern from "rchol_lap.cpp":
    int entrance(csc_form *input, stdint.uint64_t *idx_data, stdint.uint64_t idxdim, int thread)  
    ctypedef struct csc_form:
        stdint.uint64_t *row
        stdint.uint64_t *col
        double *val
        stdint.uint64_t *ret_row
        stdint.uint64_t *ret_col
        double *ret_val
        double *ret_diag
        stdint.uint64_t nsize

cdef extern from "spcol.c":
    pass

"""
cpdef random_factorization_parallel(original, thread):

    matrix_row = original.shape[0]
    # convert to laplacian, permute laplacian and extract content
    test = convert2laplacian(original)
    logic = test.copy()
    logic.setdiag(0)
    logic.eliminate_zeros()
    p_vec, val, sep = recursive_separator1(logic, 1, np.log2(thread) + 1)
    result_idx = np.cumsum(np.append(0, val))
    M = triu(test[p_vec[:, None], p_vec], format='csr') * -1

    # pass to C++, which returns the preconditioner and diagonal
    L, D = pass_to_C(M, matrix_row, thread, result_idx)

    # call pcg to solve Ax = b for x
    b = np.random.rand(matrix_row)
    b = b.astype(dtype=np.double)
    epsilon = 1e-10
    x = pcg(original[p_vec[0:-1, None], p_vec[0:-1]], b[p_vec[0:-1]], L, D, epsilon)
    pt = np.zeros(p_vec.shape[0] - 1, dtype=np.uint64)
    pt[p_vec[0:-1]] = np.arange(x.shape[0], dtype=np.uint64)
    x = x[pt]
    print('relative residual of system: ' + str(np.linalg.norm(original * x - b) / np.linalg.norm(b)))
"""

cpdef random_factorization(original, thread):

    matrix_row = original.shape[0]
    # convert to laplacian, permute laplacian and extract content
    test = sddm_to_laplacian(original)
    logic = test.copy()
    logic.setdiag(0)
    logic.eliminate_zeros()
    p_vec = np.arange(matrix_row + 1, dtype=np.uint64)
    result_idx = np.array([0, test.shape[0]], dtype=np.uint64)
    M = triu(test[p_vec[:, None], p_vec], format='csr') * -1

    # pass to C++, which returns the preconditioner and diagonal
    L, D = pass_to_C(M, matrix_row, thread, result_idx)

    # call pcg to solve Ax = b for x
    b = np.random.rand(matrix_row)
    b = b.astype(dtype=np.double)
    epsilon = 1e-10
    x = pcg(original[p_vec[0:-1, None], p_vec[0:-1]], b[p_vec[0:-1]], L, D, epsilon)
    pt = np.zeros(p_vec.shape[0] - 1, dtype=np.uint64)
    pt[p_vec[0:-1]] = np.arange(x.shape[0], dtype=np.uint64)
    x = x[pt]
    print('relative residual of system: ' + str(np.linalg.norm(original * x - b) / np.linalg.norm(b)))

 

cpdef sddm_to_laplacian(M):
    
    cdef np.ndarray[np.double_t, ndim=1] one_row = -np.squeeze(np.asarray(M.sum(axis=0)))
    np.where(np.abs(one_row) < 1e-9, 0, one_row)
    cdef double total = -one_row.sum()
    M = scipy.sparse.vstack([M, one_row], format='csr')
    one_col = np.append(one_row, total)
    M = scipy.sparse.hstack([M, one_col.reshape(-1, 1)], format='csr')
    return M


cpdef pcg(A, b, L, D, epsilon):
    n = b.shape[0]
    x = np.zeros(n, dtype=np.double)
    r = b - A * x
    prev_val = 0
    Lt = L.transpose()
    Lt = Lt.tocsr()
    niters = 0
    
    while np.linalg.norm(r) > np.linalg.norm(b) * epsilon:
        t1 = time.time()
        temp = scipy.sparse.linalg.spsolve_triangular(Lt, r)
        temp = np.divide(temp, D)
        scipy.sparse.linalg.spsolve_triangular(L, temp, lower=False, overwrite_b=True)
        t2 = time.time()
        t = t2 - t1
        #print('preconditioner solve time: ' + ("%.20f" % t))

        if niters == 0:
            p = temp
        else:
            p = temp + np.dot(r, temp) / prev_val * p

        q = A * p
        alpha = np.dot(p, r) / np.dot(p, q)
        x = x + alpha * p
        prev_val = np.dot(r, temp)
        r = r - alpha * q
        niters = niters + 1
        #print('current residual: ' + str(np.linalg.norm(r) / np.linalg.norm(b)))

    acc = np.linalg.norm(A * x - b) / np.linalg.norm(b)

    print('# CG iterations: {}'.format(niters))
    print('Relative residual: {:.2e}'.format(acc))

    return x


# calculates the separator
"""
cpdef recursive_separator1(logic, depth, target):
    cdef stdint.uint64_t *sep_ptr
    cdef np.ndarray[np.uint64_t, ndim=1] row = logic.indices.astype(dtype=np.uint64)
    cdef np.ndarray[np.uint64_t, ndim=1] col = logic.indptr.astype(dtype=np.uint64)
    if (depth == target):
        size = logic.shape[0]
        val = size
        p = np.arange(size, dtype=np.uint64)
        separator = np.zeros(0, dtype=np.uint64)
        return p, val, separator
    elif (logic.shape[0] <= 1):
        size = logic.shape[0]
        p1, v1 = recursive_separator1([], depth + 1, target)
        p2, v2 = recursive_separator1(csr_matrix((size, size)), depth + 1, target)
        val = np.append(v1, np.append(v2, 0))
        p = np.append(p1, p2)
        separator = np.zeros(0, dtype=np.uint64)
        return p, val, separator
    else:
        sep_ptr = find_separator(logic.shape[0], &(row[0]), &(col[0]))
        sep = np.asarray(<np.uint64_t[:logic.shape[0]]> sep_ptr)

        if depth == 1:
            sep[-1] = 2

        l = np.where(sep == 0)[0]
        r = np.where(sep == 1)[0]
        s = np.where(sep == 2)[0]
        newleft = logic[l[:, None], l]
        newright = logic[r[:, None], r]
        

        [p1, v1, s1] = recursive_separator1(newleft, depth + 1, target)
        [p2, v2, s2] = recursive_separator1(newright, depth + 1, target)
        separator = np.append(l[s1], np.append(r[s2], s))
        val = np.append(v1, np.append(v2, s.shape[0]))
        p = np.append(l[p1], np.append(r[p2], s))
        return p, val, separator
"""

cpdef pass_to_C(M, matrix_row, thread, result_idx):

    cdef np.ndarray[np.uint64_t, ndim=1] row = M.indices.astype(dtype=np.uint64)
    cdef np.ndarray[np.uint64_t, ndim=1] col = M.indptr.astype(dtype=np.uint64)
    cdef np.ndarray[np.double_t, ndim=1] data = M.data
    cdef np.ndarray[np.uint64_t, ndim=1] idx_data = result_idx.astype(dtype=np.uint64)

    # set up input to pass to C++
    cdef csc_form input
    input.row = &(row[0])
    input.col = &(col[0])
    input.val = &(data[0])
    input.nsize = M.shape[0]
    entrance(&input, &(idx_data[0]), idx_data.shape[0], thread) 

    # create arrays to store answer and call c++
    np_ret_indptr = np.asarray(<np.uint64_t[:matrix_row + 1]> input.ret_col)
    np_ret_indices = np.asarray(<np.uint64_t[:np_ret_indptr[matrix_row]]> input.ret_row)
    np_ret_data = np.asarray(<np.double_t[:np_ret_indptr[matrix_row]]> input.ret_val)
    D = np.asarray(<np.double_t[:matrix_row]> input.ret_diag)
    L = csr_matrix((np_ret_data, np_ret_indices, np_ret_indptr), shape=(matrix_row, matrix_row))
    return L, D


cpdef python_factorization(laplacian):
    return pass_to_C(laplacian, laplacian.shape[0] - 1, 1, np.array([0, laplacian.shape[0]], dtype=np.uint64))
