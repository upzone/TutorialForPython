#cython: language_level=3
cdef extern from "math.h":
    cpdef double sin(double x)

cpdef int myfunction(int x, int y=*)

cdef double _helper(double a)

cdef class A:
    cdef public int a,b
    cpdef foo(self, double x)