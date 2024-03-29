! This uses the output matrices from the PsHMain program to find the energy eigenvalues
!  using Allan Todd's algorithm.
! - Denton Woods
!
! Note: For larger values of omega, I am encountering crashes with the Intel Fortran compiler.
!  A similar problem is described here:
!   http://software.intel.com/en-us/forums/intel-visual-fortran-compiler-for-windows/topic/66306/
!  Also described here:
!   http://objectmix.com/fortran/35736-bug-mistake.html
!@TODO: Find compiler flags that fix this problem.  Under Windows, his solution of increasing the
!  stack size works, but I need to test the equivalent under Linux.

!@TODO: selected_real_kind
!@TODO: Get rid of *MatTemp?
!@TODO: Do we need to broadcast Omega to all nodes?

#ifndef NO_MPI
#define USE_MPI
#endif


module variables
	type PMatrix
	   real*8, pointer, dimension(:,:) :: P
	end type PMatrix
	
	type Ptr1D
		real*8, pointer, dimension(:) :: P
	end type Ptr1D
end module variables


program Energy
	use omp_lib
	!use mpi
	use variables
	implicit none
#ifdef USE_MPI
	include 'mpif.h'
	integer MpiError, MpiStatus(MPI_STATUS_SIZE)
	character(len=MPI_MAX_PROCESSOR_NAME) ProcessorName
#endif
	integer Node, TotalNodes, NodeStart, NodeEnd
	integer outputtxt, energyfile, prevresults
	integer i, j, k, m, i1, j1, ThreadNum, iargc, EnergyMinIndex, CurTerm, Omega, NumTerms, NumSets
	integer Ordering, IsTriplet, Reserved
	integer ProcNameLen, NumUsed, NumUnused, Info, Tid, MaxThreads
	integer, allocatable, dimension(:) :: UsedTerms, UsedTerms2, UnusedTerms
	integer, allocatable, dimension(:) :: EnergyMinIndexArray
	real*8, allocatable, dimension(:,:) :: PhiPhi, PhiHPhi
	real*8, dimension(5) :: Alpha, Beta, Gamma  ! @TODO: Variable length
	real*8 Upper, Lower, Tolerance, StartTime, EndTime, EnergyMin, NumTermsNode
	real*8 RemoveMe
	real*8, allocatable, dimension(:) :: EnergyMinArray
	real*8, pointer, dimension(:,:) :: PhiPhi8, PhiHPhi8  !, PhiPhiTemp, PhiHPhiTemp
	real*8, pointer, dimension(:) :: Energies, Workspace
	logical, allocatable, dimension(:) :: IsTermUsed
	logical Error
	character *100 Temp1, Temp2, Temp3, IOBuffer, EBuffer
	type(PMatrix), allocatable, dimension(:) :: PhiPhiMat, PhiHPhiMat
	type(Ptr1D), allocatable, dimension(:) :: EnergiesArray, WorkspaceArray
	integer CalcPowerTableSize
	integer, allocatable, dimension(:,:) :: PowerTable
	integer Cond1, Cond2, Cond3, Cond4, Cond5, ReadShortHeader, Res, LValue, Formalism
	integer*8 MemUsed, nt, mt
	integer RemoveMeInt

	Node = 0
	TotalNodes = 1
#ifdef USE_MPI
	! All of the MPI initialization that is required
	call MPI_Init(MpiError)
	call MPI_Comm_size(MPI_COMM_WORLD, TotalNodes, MpiError)
	call MPI_Comm_rank(MPI_COMM_WORLD, Node, MpiError)
	call MPI_Get_processor_name(ProcessorName, ProcNameLen, MpiError)
	MaxThreads = omp_get_max_threads()

	! Enumerate the threads on the different nodes to aid in debugging (and to see if we got all of the requested nodes).
	!$omp parallel shared(TotalNodes,MaxThreads,ProcessorName) private(ThreadNum)
		ThreadNum = omp_get_thread_num()
		write (*,'(a,i3,a,i3,a,i3,a,i3,a,a)') 'Thread', ThreadNum, ' of', MaxThreads, ': Node', Node, ' of', TotalNodes, ': on ', ProcessorName
	!$omp end parallel
#endif
	

	! This tolerance may need to be changed.  This determines whether a term is problematic based on whether the
	!  energies of the upper and lower triangular matrices differs by more than this amount.	
	!Tolerance = 1d-6
	Tolerance = 1d-5

	outputtxt = 9
	energyfile = 10
	prevresults = 11

	! Uncomment this for debugging purposes.
	!call omp_set_num_threads(1)
	MaxThreads = omp_get_max_threads()
	write (*,*) 'Max threads:', MaxThreads

	! This allows the possibility of using different input and output files than the defaults.
	!  This mainly lets me run this program on multiple computers at the same time without
	!  one overwriting the results from another.  If the program is called without any
	!  command-line arguments, it uses the default filenames.
	if (Node == 0) then
		if (iargc() == 2) then
			call getarg(1, IOBuffer)
			!open (outputtxt, FILE=IOBuffer)
			open(unit=outputtxt, file=IOBuffer, status="old")
			call getarg(2, IOBuffer)
			open (energyfile, FILE=IOBuffer, status='unknown')
		else if (iargc() == 3) then
			call getarg(1, IOBuffer)
			!open (outputtxt, FILE=IOBuffer)
			open (unit=outputtxt, file=IOBuffer, status="old")
			call getarg(2, IOBuffer)
			open (energyfile, FILE=IOBuffer, status='unknown')
			call getarg(3, IOBuffer)  ! Use previous output as an input to continue computation.
			open (prevresults, FILE=IOBuffer)
		else
			!open (outputtxt, FILE='output.txt')
			open (unit=outputtxt, file='output.psh', status="old")
			open (energyfile, FILE='energies.txt', status='unknown')
			IOBuffer = 'energies.txt'
		endif

		! Get the start time to determine the duration of the program.
		StartTime = omp_get_wtime()

		! Skips some of the header information.
!		read (outputtxt,*) Temp1, Temp2, Omega  ! The only thing in this line we want is the actual omega.
!		read (outputtxt,*) Temp1, Temp2, Alpha
!		read (outputtxt,*) Temp1, Temp2, Beta
!		read (outputtxt,*) Temp1, Temp2, Gamma
!		read (outputtxt,*) Temp1, Temp2, Temp3, NumTerms
!		read (outputtxt,*)

		Res = ReadShortHeader(outputtxt, Omega, LValue, IsTriplet, Formalism, Ordering, NumTerms, Alpha, Beta, Gamma, NumSets)
		if (Res == -1) then
			stop  ! Error reading short-range file header
		end if

		NumTerms = NumTerms / 2

		write (*,*) 'Omega:', Omega
		write (*,*) 'Number of terms:', NumTerms
		write (*,*) 'Alpha:', Alpha(1), 'Beta:', Beta(1), 'Gamma:', Gamma(1)
		write (energyfile,*) 'Omega:', Omega
		write (energyfile,*) 'Number of terms:', NumTerms
		write (energyfile,'(a,f11.8,a,f11.8,a,f11.8)') ' Alpha: ', Alpha(1), '  Beta: ', Beta(1), '  Gamma: ', Gamma(1)  !@TODO: Output all
	endif  ! Only want to do this once, for the first process.

#ifdef USE_MPI
	! Send this to all processes so that they can properly allocate the matrices.
	call MPI_BCAST(Omega, 1, MPI_INTEGER, 0, MPI_COMM_WORLD, MpiError)
	call MPI_BCAST(NumTerms, 1, MPI_INTEGER, 0, MPI_COMM_WORLD, MpiError)
#endif

	allocate(PhiPhi(NumTerms*2,NumTerms*2))
	allocate(PhiHPhi(NumTerms*2,NumTerms*2))
	allocate(UsedTerms(NumTerms))
	allocate(UsedTerms2(NumTerms*2))
	allocate(UnusedTerms(NumTerms))
	allocate(IsTermUsed(NumTerms))
	allocate(PhiPhiMat(0:MaxThreads))
	allocate(PhiHPhiMat(0:MaxThreads))
	allocate(EnergiesArray(0:MaxThreads))
	allocate(WorkspaceArray(0:MaxThreads))
	do i = 0, MaxThreads-1, 1
		allocate(PhiPhiMat(i)%P(NumTerms*2,NumTerms*2))
		allocate(PhiHPhiMat(i)%P(NumTerms*2,NumTerms*2))
		allocate(EnergiesArray(i)%P(NumTerms*2))
		allocate(WorkspaceArray(i)%P(3*NumTerms*2))
	end do

	nt = NumTerms
	mt = MaxThreads
	if (Node==0) write (*,*) "NumTerms and MaxThreads:", NumTerms, MaxThreads
	MemUsed = nt*nt*8_8  !PhiPhi
	MemUsed = MemUsed + nt*nt*8_8  !PhiHPhi
	MemUsed = MemUsed + nt*8_8  !UsedTerms
	MemUsed = MemUsed + nt*8_8  !UnusedTerms
	MemUsed = MemUsed + nt*4_8  !IsTermUsed
	MemUsed = MemUsed + mt*8_8  !PhiPhiMat
	MemUsed = MemUsed + mt*8_8  !PhiHPhiMat
	MemUsed = MemUsed + mt*8_8  !EnergiesArray
	MemUsed = MemUsed + mt*8_8  !WorkspaceArray
	MemUsed = MemUsed + nt*nt*mt*8_8  !PhiPhiMat
	MemUsed = MemUsed + nt*nt*mt*8_8  !PhiHPhiMat
	MemUsed = MemUsed + nt*mt*8_8  !EnergiesArray
	MemUsed = MemUsed + 3*nt*mt*8_8  !WorkspaceArray
	if (Node == 0) then
		MemUsed = MemUsed + TotalNodes*8_8 !EnergyMinArray
		MemUsed = MemUsed + TotalNodes*4_8 !EnergyMinIndexArray
	endif
	write (*,*) "Memory used by node", Node, "=", MemUsed

	! Initialize with no terms being used.
	IsTermUsed = .false.

	! Read in our matrices.
	if (Node == 0) then
		write (*,*) "Reading in matrices..."
		do i = 1, NumTerms*2, 1
			do j = 1, NumTerms*2, 1
				read (outputtxt,*) i1, j1, PhiPhi(i,j), PhiHPhi(i,j)
				!read (outputtxt) PhiPhi(i,j)
			enddo
		enddo

		! Divide every entry in PhiHPhi by 2, since we calculated <phi_i|2H|phi_j> in equation (3.22).
		PhiHPhi = PhiHPhi / 2.0d0
		write (*,*) "Finished reading in matrices."
	endif
	
#ifdef USE_MPI
	! Broadcast these matrices to all processes.
	if (Node == 0) then
		write (*,*) 'TotalNodes', TotalNodes
		do i = 1, TotalNodes-1, 1
			write (*,*) 'Rank', i
			do j = 1, NumTerms*2, 1
				!call MPI_BCAST(PhiPhi(1,j), NumTerms, MPI_DOUBLE_PRECISION, 0, MPI_COMM_WORLD, MpiError)
				!call MPI_BCAST(PhiHPhi(1,j), NumTerms, MPI_DOUBLE_PRECISION, 0, MPI_COMM_WORLD, MpiError)
				call MPI_Send(PhiPhi(1,j), NumTerms*2, MPI_DOUBLE_PRECISION, i, 0, MPI_COMM_WORLD, MpiError)
				call MPI_Send(PhiHPhi(1,j), NumTerms*2, MPI_DOUBLE_PRECISION, i, 0, MPI_COMM_WORLD, MpiError)
			enddo
		enddo
	else
		do j = 1, NumTerms*2, 1
			call MPI_Recv(PhiPhi(1,j), NumTerms*2, MPI_DOUBLE_PRECISION, 0, 0, MPI_COMM_WORLD, MpiStatus, MpiError)
			call MPI_Recv(PhiHPhi(1,j), NumTerms*2, MPI_DOUBLE_PRECISION, 0, 0, MPI_COMM_WORLD, MpiStatus, MpiError)
		enddo
	endif

	call MPI_BCAST(PhiPhi,  NumTerms*NumTerms*4, MPI_DOUBLE_PRECISION, 0, MPI_COMM_WORLD, MpiError)
	call MPI_BCAST(PhiHPhi, NumTerms*NumTerms*4, MPI_DOUBLE_PRECISION, 0, MPI_COMM_WORLD, MpiError)
#endif
	! Allocate space to collate the lowest energies from each node.
	if (Node == 0) then
		write (*,*) "Finished broadcasting matrices to all nodes."
		allocate(EnergyMinArray(0:TotalNodes-1))
		allocate(EnergyMinIndexArray(0:TotalNodes-1))
	endif

	NumUsed = 0
	UsedTerms = 0
	! Initialize our UnusedTerms array with all terms.
	do i = 1, NumTerms, 1
		UnusedTerms(i) = i
	enddo

	! Used to continue the computation if it was stopped for whatever reason.
	if (Node == 0) then
		if (iargc() == 3) then
			!@TODO: Read to the end of the file to determine NumUsed parameter.
			!  I can use the reshape function in Fortran to do this.
			read (prevresults,*) NumUsed
			read (prevresults,*)  ! Skip these
			read (prevresults,*)  !  three lines
			read (prevresults,*)
			do i = 1, NumUsed, 1
				read (prevresults,*) EnergyMinIndex
				UsedTerms(i) = EnergyMinIndex
				UsedTerms2(2*i-1) = EnergyMinIndex
				UsedTerms2(2*i) = EnergyMinIndex + NumTerms
				IsTermUsed(EnergyMinIndex) = .true.
			enddo

			!@TODO: Could there be a problem with not keeping a count of the terms?
			! Puts the unused terms into an array.
			j = 0
			do i = 1, NumTerms, 1
				if (IsTermUsed(i) .eqv. .false.) then
					j = j + 1
					UnusedTerms(j) = i
				endif
			enddo

			if (j /= NumTerms - NumUsed) then
				write (*,*) 'Error in number of unused terms', j, NumTerms - NumUsed
				stop
			endif
		endif

		write (*,*) 'Starting at term:', NumUsed
		write (energyfile,*) 'Starting at term:', NumUsed
		write (*,*)
	endif

#ifdef USE_MPI
	! Synchronize NumUsed, etc. with all processes (only valid for root process at this point).
	call MPI_BCAST(NumUsed, 1, MPI_INTEGER, 0, MPI_COMM_WORLD, MpiError)
	call MPI_BCAST(UsedTerms, NumTerms, MPI_INTEGER, 0, MPI_COMM_WORLD, MpiError)
	call MPI_BCAST(UnusedTerms, NumTerms, MPI_INTEGER, 0, MPI_COMM_WORLD, MpiError)
	call MPI_BCAST(IsTermUsed, NumTerms, MPI_LOGICAL, 0, MPI_COMM_WORLD, MpiError)
#endif
	NumUnused = NumTerms - NumUsed
	write (*,*) 'Number of unused terms: ', NumUnused


	do m = NumUsed+1, NumTerms, 1
		EnergyMin = 0.0d0
		EnergyMinIndex = -1

		! Determine for each process which terms it should investigate.
		if (Node == 0) then
			NumTermsNode = NumUnused / real(TotalNodes)
#ifdef USE_MPI
			do k = 1, TotalNodes - 1, 1
				NodeStart = NumTermsNode * k + 1
				NodeEnd = NumTermsNode * (k+1)
				call MPI_Send(NodeStart, 1, MPI_INTEGER, k, 1, MPI_COMM_WORLD, MpiError)
				call MPI_Send(NodeEnd, 1, MPI_INTEGER, k, 2, MPI_COMM_WORLD, MpiError)
			enddo
#endif
			! This is the set of values for the root node to take.
			NodeStart = 1
			NodeEnd = NumTermsNode * (Node+1)
#ifdef USE_MPI
		else
			call MPI_Recv(NodeStart, 1, MPI_INTEGER, 0, 1, MPI_COMM_WORLD, MpiStatus, MpiError)
			call MPI_Recv(NodeEnd, 1, MPI_INTEGER, 0, 2, MPI_COMM_WORLD, MpiStatus, MpiError)
#endif
		endif


		!$omp parallel shared(i,NumTerms,PhiPhi,PhiHPhi,UsedTerms,UsedTerms2,NumUsed,EnergyMin,EnergyMinIndex,m,IsTermUsed,PhiPhiMat,PhiHPhiMat)
		!$omp do private(PhiPhi8,PhiHPhi8,j,k,Upper,Lower,Energies,Workspace,Info,Tid,Error,CurTerm)
		do i = NodeStart, NodeEnd, 1
			Tid = omp_get_thread_num()
			CurTerm = UnusedTerms(i)
			if (IsTermUsed(CurTerm) .eqv. .true.) cycle  ! Not really needed anymore
			!write (*,*) "Checking term", i, "on thread", Tid

			! Assign our pointers to the array of structures so that each thread has its own copy of PhiPhi and PhiHPhi.
			PhiPhi8 => PhiPhiMat(Tid)%P
			PhiHPhi8 => PhiHPhiMat(Tid)%P
			Energies => EnergiesArray(Tid)%P
			Workspace => WorkspaceArray(Tid)%P

			! Have to clear out these matrices, because LAPACK gives strange results if the rest of the
			!  matrix we are not using is non-zero.  We are only using the sub-matrix of size
			!  (NumUsed+1)x(NumUsed+1).
			PhiPhi8 = 0.0d0
			PhiHPhi8 = 0.0d0

			! Create our sub-matrix with the terms chosen for lowest energies.  The terms are stored in
			!  the UsedTerms2 array.  This sub-matrix is the same for every iteration in this loop.
			do j = 1, NumUsed*2, 1
				do k = 1, NumUsed*2, 1
					PhiPhi8(j,k) = PhiPhi(UsedTerms2(j),UsedTerms2(k))
					PhiHPhi8(j,k) = PhiHPhi(UsedTerms2(j),UsedTerms2(k))
				enddo
			enddo

			!$omp critical(build)
			!@TODO: Is there a more efficient way to do this?
			! If this is not enclosed by critical sections, then it will give really strange results.
			! Construct new row with term to test. - phi1
			UsedTerms(NumUsed+1) = CurTerm
			UsedTerms2(NumUsed*2+1) = CurTerm
			do j = 1, NumUsed*2+1, 1
				RemoveMeInt = UsedTerms2(j)
				PhiPhi8(NumUsed*2+1,j) = PhiPhi(CurTerm,UsedTerms2(j))
				PhiHPhi8(NumUsed*2+1,j) = PhiHPhi(CurTerm,UsedTerms2(j))
			enddo
			! Construct new column. - phi1
			do j = 1, NumUsed*2+1, 1
				RemoveMeInt = UsedTerms2(j)
				PhiPhi8(j,NumUsed*2+1) = PhiPhi(UsedTerms2(j),CurTerm)
				PhiHPhi8(j,NumUsed*2+1) = PhiHPhi(UsedTerms2(j),CurTerm)
			enddo
			! Construct new row with term to test. - phi2
			UsedTerms2(NumUsed*2+2) = CurTerm + NumTerms
			do j = 1, NumUsed*2+2, 1
				RemoveMeInt = UsedTerms2(j)
				PhiPhi8(NumUsed*2+2,j) = PhiPhi(CurTerm+NumTerms,UsedTerms2(j))
				PhiHPhi8(NumUsed*2+2,j) = PhiHPhi(CurTerm+NumTerms,UsedTerms2(j))
			enddo
			! Construct new column. - phi2
			do j = 1, NumUsed*2+2, 1
				RemoveMeInt = UsedTerms2(j)
				PhiPhi8(j,NumUsed*2+2) = PhiPhi(UsedTerms2(j),CurTerm+NumTerms)
				PhiHPhi8(j,NumUsed*2+2) = PhiHPhi(UsedTerms2(j),CurTerm+NumTerms)
			enddo
			!$omp end critical(build)

			Error = .false.
			! Finds the NumUsed+1 eigenvalues of the upper triangular matrix.
			call dsygv(1, 'N', 'U', 2*(NumUsed+1), PhiHPhi8, NumTerms*2, PhiPhi8, NumTerms*2, Energies, Workspace, 3*NumTerms*2, Info)
			if (Info /= 0) then
				write (energyfile,*) 'Upper dsygv error code:', Info, 'Term:', CurTerm
				Error = .true.
			endif
			Upper = Energies(1)

			! Create our sub-matrix with the terms chosen for lowest energies.  The terms are stored in
			!  the UsedTerms array.  This sub-matrix is the same for every iteration in this loop.
			do j = 1, NumUsed*2, 1
				do k = 1, NumUsed*2, 1
					PhiPhi8(j,k) = PhiPhi(UsedTerms2(j),UsedTerms2(k))
					PhiHPhi8(j,k) = PhiHPhi(UsedTerms2(j),UsedTerms2(k))
				enddo
			enddo

			!$omp critical(build)
			! Exact same building code as before.
			! Construct new row with term to test.
			UsedTerms(NumUsed+1) = CurTerm
			UsedTerms2(NumUsed*2+1) = CurTerm
			do j = 1, NumUsed*2+1, 1
				RemoveMeInt = UsedTerms2(j)
				PhiPhi8(NumUsed*2+1,j) = PhiPhi(CurTerm,UsedTerms2(j))
				PhiHPhi8(NumUsed*2+1,j) = PhiHPhi(CurTerm,UsedTerms2(j))
			enddo
			! Construct new column. - phi1
			do j = 1, NumUsed*2+1, 1
				RemoveMeInt = UsedTerms2(j)
				PhiPhi8(j,NumUsed*2+1) = PhiPhi(UsedTerms2(j),CurTerm)
				PhiHPhi8(j,NumUsed*2+1) = PhiHPhi(UsedTerms2(j),CurTerm)
			enddo
			! Construct new row with term to test. - phi2
			UsedTerms2(NumUsed*2+2) = CurTerm + NumTerms
			do j = 1, NumUsed*2+2, 1
				RemoveMeInt = UsedTerms2(j)
				PhiPhi8(NumUsed*2+2,j) = PhiPhi(CurTerm+NumTerms,UsedTerms2(j))
				PhiHPhi8(NumUsed*2+2,j) = PhiHPhi(CurTerm+NumTerms,UsedTerms2(j))
			enddo
			! Construct new column. - phi2
			do j = 1, NumUsed*2+2, 1
				RemoveMeInt = UsedTerms2(j)
				PhiPhi8(j,NumUsed*2+2) = PhiPhi(UsedTerms2(j),CurTerm+NumTerms)
				PhiHPhi8(j,NumUsed*2+2) = PhiHPhi(UsedTerms2(j),CurTerm+NumTerms)
			enddo
			!$omp end critical(build)

			! If there was an error for the upper triangular matrix eigenvalues, there is no reason to waste computation
			!  time finding the lower triangular matrix eigenvalues.  This term is not used if Error = true.
			if (Error .eqv. .false.) then
				! Finds the NumUsed+1 eigenvalues of the lower triangular matrix.
				call dsygv(1, 'N', 'L', 2*(NumUsed+1), PhiHPhi8, NumTerms*2, PhiPhi8, NumTerms*2, Energies, Workspace, 3*NumTerms*2, Info)
				if (Info /= 0) then
					write (energyfile,*) 'Lower dsygv error code:', Info, 'Term:', CurTerm
					Error = .true.
				endif
				Lower = Energies(1)
			endif

			if (dabs(Upper-Lower) > Tolerance .and. (Upper /= 0 .and. Lower /= 0)) then
				Error = .true.
				write (energyfile,*) 'Upper and Lower Difference:', CurTerm, dabs(Upper-Lower)
			endif
			
			if (Error .eqv. .false.) then
				! This section must be enclosed as a critical.  If not, one thread could modify EnergyMin while the other is
				!  also modifying EnergyMinIndex.  These two variables must be updated at the same time.
				! Checks to see if the energy found with adding on this term is the lowest and saves it if it is.
				!$omp critical(testenergy)
				if ((Upper+Lower)/2.0d0 < EnergyMin) then
					EnergyMin = (Upper+Lower)/2.0d0
					EnergyMinIndex = CurTerm
				endif
				!$omp end critical(testenergy)
			else
				!@TODO: Do we want to differentiate between the terms omitted by LAPACK errors and terms omitted by the differences
				! being greater than the Tolerance variable?
				write (energyfile,*) 'Problematic term number:', CurTerm
				!write (*,*) 'Omitting term:', CurTerm, NumUsed, Upper, Lower, dabs(Upper-Lower)
			endif
		enddo
		!$omp end do
		!$omp end parallel

		! Collect all of the energies from the different processes and compare.
		if (Node == 0) then
			!write (*,*) 'Node:', Node, ' ', EnergyMin, EnergyMinIndex
			EnergyMinArray(0) = EnergyMin
			EnergyMinIndexArray(0) = EnergyMinIndex
#ifdef USE_MPI
			do k = 1, TotalNodes - 1, 1
				call MPI_Recv(EnergyMinArray(k), 1, MPI_REAL8, k, 1, MPI_COMM_WORLD, MpiStatus, MpiError)
				call MPI_Recv(EnergyMinIndexArray(k), 1, MPI_INTEGER, k, 2, MPI_COMM_WORLD, MpiStatus, MpiError)
			enddo
#endif

			EnergyMin = 0.0d0
			EnergyMinIndex = -1
			do k = 0, TotalNodes - 1, 1
				!write (*,*) 'Lowest energy: ', EnergyMin, EnergyMinIndex
				if (EnergyMinIndexArray(k) == -1) cycle  ! No valid terms were found in that sub-block.
				if (EnergyMinArray(k) < EnergyMin) then
					EnergyMin = EnergyMinArray(k)
					EnergyMinIndex = EnergyMinIndexArray(k)
				endif
			enddo
		else
			! Tell the main process what term yields the lowest energy and what that energy is.
			!write (*,*) 'Node:', Node, ' ', EnergyMin, EnergyMinIndex
#ifdef USE_MPI
			call MPI_Send(EnergyMin, 1, MPI_REAL8, 0, 1, MPI_COMM_WORLD, MpiError)
			call MPI_Send(EnergyMinIndex, 1, MPI_INTEGER, 0, 2, MPI_COMM_WORLD, MpiError)
#endif			
		endif

#ifdef USE_MPI
		! Synchronize the lowest energy with all processes.
		call MPI_BCAST(EnergyMin, 1, MPI_REAL8, 0, MPI_COMM_WORLD, MpiError)
		call MPI_BCAST(EnergyMinIndex, 1, MPI_INTEGER, 0, MPI_COMM_WORLD, MpiError)
#endif

		if (EnergyMinIndex == -1) then
			exit  ! No more terms have been added, so we are done.  The rest of the terms are omitted, because they are problematic.
		endif

		! Check to see if we have any useable terms left.
		if (Node == 0) then
			NumUsed = NumUsed + 1
			NumUnused = NumUnused - 1
			UsedTerms(NumUsed) = EnergyMinIndex
			UsedTerms2(NumUsed*2-1) = EnergyMinIndex
			UsedTerms2(NumUsed*2) = EnergyMinIndex+NumTerms
			do i = 1, NumUnused, 1
				if (UnusedTerms(i) == EnergyMinIndex) exit
			enddo

			UnusedTerms(i:NumTerms-1) = UnusedTerms(i+1:NumTerms)  ! Remove the used term from the unused terms list.
			IsTermUsed(EnergyMinIndex) = .true.
			write (energyfile,*) EnergyMinIndex, NumUsed, EnergyMin
			write (*,*) EnergyMinIndex, NumUsed, EnergyMin

			! I like to see the outputs as they are generated, so the energyfile gets flushed at each write.  There is screen
			!  output, but it does not get shown to the user until the program has completed if it is run on the computer cluster.
			!  Normally, flushing after every write is a bad thing, but the writes are far enough apart in time that it is
			!  not an issue.
			call flush(energyfile)
		endif

#ifdef USE_MPI
		call MPI_BCAST(NumUsed, 1, MPI_INTEGER, 0, MPI_COMM_WORLD, MpiError)
		call MPI_BCAST(NumUnused, 1, MPI_INTEGER, 0, MPI_COMM_WORLD, MpiError)
		call MPI_BCAST(UsedTerms, NumTerms, MPI_INTEGER, 0, MPI_COMM_WORLD, MpiError)
		call MPI_BCAST(UnusedTerms, NumTerms, MPI_INTEGER, 0, MPI_COMM_WORLD, MpiError)
		call MPI_BCAST(IsTermUsed, NumTerms, MPI_LOGICAL, 0, MPI_COMM_WORLD, MpiError)
#endif
	enddo

	if (Node == 0) then
		write (energyfile,*) 'Number of terms used:', NumUsed
		write (energyfile,*) 'Number of terms omitted:', NumTerms - NumUsed
		write (*,*) 'Number of terms used:', NumUsed
		write (*,*) 'Number of terms omitted:', NumTerms - NumUsed

		! Get the end time to find the duration of the program.
		EndTime = omp_get_wtime()
		write (*,*) 'Time taken:', EndTime - StartTime
		write (energyfile,*)
		write (energyfile,*) 'Time taken (s):', EndTime - StartTime, '  (min):', (EndTime - StartTime) / 60.0
	endif

	! This code outputs the first 10 eigenvalues to see if there is a stabilization.  We output the first 10 eigenvalues
	!  for the first 10 terms, then add another, recalculate, and so on.  For a reference, see Peter Van Reeth's 2004
	!  paper (doi:10.1016/j.nimb.2004.03.045).
	if (Node == 0) then
		write (*,*)
		write (*,*) 'Calculating the first 10 eigenvalues'
		write (energyfile,*)
		do j = 1, NumUsed, 1
			! Recreate final matrices.
			PhiPhi8 => PhiPhiMat(0)%P
			PhiHPhi8 => PhiHPhiMat(0)%P
			Energies => EnergiesArray(0)%P
			Workspace => WorkspaceArray(0)%P
			PhiPhi8 = 0.0d0
			PhiHPhi8 = 0.0d0

			do m = 1, j*2, 1
				do k = 1, j*2, 1
					PhiPhi8(m,k) = PhiPhi(UsedTerms2(m),UsedTerms2(k))
					PhiHPhi8(m,k) = PhiHPhi(UsedTerms2(m),UsedTerms2(k))
				enddo
			enddo

			call dsygv(1, 'N', 'L', 2*j, PhiHPhi8, NumTerms*2, PhiPhi8, NumTerms*2, Energies, Workspace, 3*NumTerms*2-1, Info)
			! Writes the eigenvalues.  We should not need to check Info, since only "good" terms are used.
			! This output is formatted properly for inclusion into Excel as a comma-separated value (.csv) file.
			write (*,*) UsedTerms(j), j, Energies(1)
!			write (energyfile,"(i4)",advance='no') j
!			do i = 1, 10, 1
!				write (energyfile,"(a,d21.14)",advance='no') ', ', Energies(i)
!			enddo
!			write (energyfile,*) ' '  ! Finish the line
			! Note: I had problems with the above code putting an extra blank line between outputs.
			write (energyfile,"(i5,a,d21.14,a,d21.14,a,d21.14,a,d21.14,a,d21.14,a,d21.14,a,d21.14,a,d21.14,a,d21.14,a,d21.14)") &
				j,', ',Energies(1),', ',Energies(2),', ',Energies(3),', ',Energies(4), ', ',Energies(5),', ',Energies(6),&
				', ',Energies(7),', ',Energies(8),', ',Energies(9),', ',Energies(10)
		enddo
	endif

	if (Node == 0) then  ! Was only allocated for the main process
		deallocate(EnergyMinArray)
		deallocate(EnergyMinIndexArray)
	endif

	! Clean up everything...
	deallocate(IsTermUsed)
	deallocate(UnusedTerms)
	deallocate(UsedTerms)
	deallocate(PhiPhi)
	deallocate(PhiHPhi)
	do i = 0, MaxThreads-1, 1
		deallocate(PhiPhiMat(i)%P)
		deallocate(PhiHPhiMat(i)%P)
		deallocate(EnergiesArray(i)%P)
		deallocate(WorkspaceArray(i)%P)
	end do
	deallocate(PhiPhiMat)
	deallocate(PhiHPhiMat)
	deallocate(EnergiesArray)
	deallocate(WorkspaceArray)

	! ...and close all open files.
	if (Node == 0) then  ! Do not want to try closing it from every process.
		if (iargc() == 3) close(prevresults)
		close(outputtxt)
		close(energyfile)
	endif

#ifdef USE_MPI
	! Finally shut down MPI.
	call MPI_Finalize(MpiError)
#endif

stop
end program


integer function CalcPowerTableSize(Omega)
	integer Omega  ! This sets the limits on the terms.
	integer NumTerms  ! The total number of terms
	integer ki, li, mi, ni, pi, qi  ! These are the exponents we are determining.

	NumTerms = 0
	do ki = 0, Omega, 1
		do li = 0, Omega, 1
			do mi = 0, Omega, 1
				do ni = 0, Omega, 1
					do pi = 0, Omega, 1
						do qi = 0, Omega, 1
							if (ki + li + mi + ni + pi + qi <= Omega) then
								!if (ki>li) cycle
								!if (ki==li .and. qi>pi) cycle
								NumTerms = NumTerms + 1
							endif
						enddo
					enddo
				enddo
			enddo
		enddo
	enddo
	
	CalcPowerTableSize = NumTerms
	return
end


subroutine GenOmegaPowerTable(Omega, PowerTable, ArraySize)
	!implicit none
	integer Omega  ! This sets the limits on the terms.
	integer ArraySize
	integer, dimension(ArraySize,6) :: PowerTable
	integer NumTerm  ! The number of the current term
	integer om, ki, li, mi, ni, pi, qi  ! These are the exponents we are determining.

	NumTerm = 0
	do om = 0, Omega, 1
		do ki = 0, Omega, 1
			do li = 0, Omega, 1
				do mi = 0, Omega, 1
					do ni = 0, Omega, 1
						do pi = 0, Omega, 1
							do qi = 0, Omega, 1
								if (ki + li + mi + ni + pi + qi == om) then
									!if (ki + li + mi + ni + pi + qi <= Omega) then
									!if (ki>li) cycle
									!if (ki==li .and. qi>pi) cycle

									NumTerm = NumTerm + 1
									PowerTable(NumTerm,1) = ki
									PowerTable(NumTerm,2) = li
									PowerTable(NumTerm,3) = mi
									PowerTable(NumTerm,4) = ni
									PowerTable(NumTerm,5) = pi
									PowerTable(NumTerm,6) = qi
									
									!write (*,*) ki, li, mi, ni, pi, qi, ki + li + mi + ni + pi + qi
								endif
							enddo
						enddo
					enddo
				enddo
			enddo
		enddo
	enddo

	return
end


! Reads in the short-range file header
!@TODO: Put in a proper XML reader. Badly formatted files will fail horribly.
integer function ReadShortHeader(FileShortRange, Omega, LValue, IsTriplet, Formalism, Ordering, NumShortTerms, Alpha, Beta, Gamma, NumSets)
	implicit none
	character(len=1000) Line  ! Much bigger than we should ever need (lines are usually less than 100 characters wide)
	integer FileShortRange, Omega, NumShortTerms, LValue, IsTriplet, Formalism, Ordering, NumSets
	real*8, dimension(5) :: Alpha, Beta, Gamma
	integer i, StrStart, StrEnd

	! Default values to determine later whether these were found in the header	
	Alpha = 0;  Beta = 0;  Gamma = 0
	Omega = -1;  LValue = -1;  IsTriplet = -1;  
	
	do i = 1, 100, 1  !@TODO: Do not hardcode like this
		read(FileShortRange, '(a)') Line
		StrStart = index(Line, "</header>")
		if (StrStart > 0) then
			write (*,*) "Finished processing header"
			exit
		end if

		! Find L
		StrStart = index(Line, "<lvalue>")
		if (StrStart > 0) then
			StrStart = index(Line, ">") + 1
			StrEnd = index(Line, "</lvalue>")
			read (Line(StrStart:StrEnd-1),*) LValue
		end if
		! Find omega
		StrStart = index(Line, "<omega>")
		if (StrStart > 0) then
			StrStart = index(Line, ">") + 1
			StrEnd = index(Line, "</omega>")
			read (Line(StrStart:StrEnd-1),*) Omega
		end if
		! Find number of terms
		StrStart = index(Line, "<numterms>")
		if (StrStart > 0) then
			StrStart = index(Line, ">") + 1
			StrEnd = index(Line, "</numterms>")
			read (Line(StrStart:StrEnd-1),*) NumShortTerms
		end if

		! Find number of sets of nonlinear parameters
		StrStart = index(Line, "<numsets>")
		if (StrStart > 0) then
			StrStart = index(Line, ">") + 1
			StrEnd = index(Line, "</numsets>")
			read (Line(StrStart:StrEnd-1),*) NumSets
		end if
		! Find alpha
		StrStart = index(Line, "<alpha>")
		if (StrStart > 0) then
			StrStart = index(Line, ">") + 1
			StrEnd = index(Line, "</alpha>")
			read (Line(StrStart:StrEnd-1),*) Alpha(1)  ! Convert from string to double
		end if
		! Find beta
		StrStart = index(Line, "<beta>")
		if (StrStart > 0) then
			StrStart = index(Line, ">") + 1
			StrEnd = index(Line, "</beta>")
			read (Line(StrStart:StrEnd-1),*) Beta(1)
		end if
		! Find gamma
		StrStart = index(Line, "<gamma>")
		if (StrStart > 0) then
			StrStart = index(Line, ">") + 1
			StrEnd = index(Line, "</gamma>")
			read (Line(StrStart:StrEnd-1),*) Gamma(1)
		end if
		
		! Find spin
		StrStart = index(Line, "<spin>")
		if (StrStart > 0) then
			if (index(Line, "Singlet") > 0) then
				IsTriplet = 0
			else if (index(Line, "Triplet") > 0) then
				IsTriplet = 1
			else
				write (*,*) "Spin could not be determined!"
				stop
			end if
		end if
	end do
	
	! Find start of data section
	do i = 1, 100, 1  !@TODO: Do not hardcode like this
		read(FileShortRange, '(a)') Line
		StrStart = index(Line, "<data>")
		if (StrStart > 0) then
			write (*,*) "Found data section"
			exit
		end if
	end do
	
	!@TODO: Check whether all values were found
	ReadShortHeader = 0
	return
end

