FC = mpif90 -f90=ifort
#FC = gfortran
#FC = ifort
#FFLAGS = -r8
#FFLAGS   = -fdefault-real-8 -O2 -fopenmp
#FFLAGS = -fopenmp -O2
#FFLAGS = -openmp -parallel -O3 -xHost
#FFLAGS = -openmp -xHost -heap-arrays -g
FFLAGS = -openmp -xHost -g
#LDLIBS = -lmkl_intel_thread -lmkl_lapack95 -lmkl_core -lmkl_sequential -lmkl_blacs -lmkl_blas95 -lmkl_lapack
#LDLIBS = -lmkl_core -lmkl_lapack95 -lmkl_sequential -lm -lmkl_intel -lmkl_intel_thread -lmkl_blas95
#LDLIBS = -llapack -lmkl_intel_thread -lmkl_core -lmkl_sequential
#LDLIBS = -lmkl_lapack95_ilp64 -lmkl_intel_thread -lmkl_core -lmkl_sequential
LDLIBS = -lmkl_intel_lp64 -lmkl_intel_thread -lmkl_core -lpthread -lm
#LDLIBS = -llapack -lblas
OBJS = Energy.o invsg.o leq1s.o

Energy: $(OBJS)
	$(FC) $(FFLAGS) -o $@ $(OBJS) $(LDLIBS) -L$MKLROOT/lib/em64t

Energy.o: Energy.f90
	$(FC) -c $(FFLAGS) Energy.f90

invsg.o: invsg.f90
	$(FC) -c $(FFLAGS) invsg.f90
	
leq1s.o: leq1s.f90
	$(FC) -c $(FFLAGS) leq1s.f90
	
	
clean:
	rm -f myprog *.o *.log *.fln *~
