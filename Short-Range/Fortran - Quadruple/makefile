FC = ifort
CC = gcc
OBJDIR = obj
#FFLAGS = -O2 -132 -parallel -openmp -gen-interfaces -warn interfaces
FFLAGS = -O2 -132 -parallel -openmp
LDLIBS = -llapack -lblas -lgsl -lgslcblas -lstdc++
#OBJS = PsHMain.o Minimize.o gamma.o HylleraasIntegral.o HylleraasIntegralRecursion.o dilog.o ydplog.o ygam.o ygam1s.o idx.o invsg.o leq1s.o
OBJS = $(addprefix $(OBJDIR)/, PsHMain.o Minimize.o HylleraasIntegral.o lu.o GeneralAsymptotic/DrakeYan97.o GeneralAsymptotic/3j.o GeneralAsymptotic/6j.o GeneralAsymptotic/Asymptotic.o)

PsHMain: $(OBJS)
	$(FC) $(FFLAGS) -o $@ $(OBJS) $(LDLIBS)

$(OBJDIR)/%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

$(OBJDIR)/%.o: %.f90
	$(FC) $(FFLAGS) -c -o $@ $<

# http://www.gnu.org/software/make/manual/make.html#Prerequisite-Types
$(OBJS): | $(OBJDIR)

$(OBJDIR):
	mkdir $(OBJDIR)
	mkdir $(OBJDIR)/GeneralAsymptotic

clean:
	rm -f PsHMain $(OBJDIR)/*.o

