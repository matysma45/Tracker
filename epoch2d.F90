! Copyright (C) 2010-2015 Keith Bennett <K.Bennett@warwick.ac.uk>
! Copyright (C) 2009-2012 Chris Brady <C.S.Brady@warwick.ac.uk>
! Copyright (C) 2012      Martin Ramsay <M.G.Ramsay@warwick.ac.uk>
!
! This program is free software: you can redistribute it and/or modify
! it under the terms of the GNU General Public License as published by
! the Free Software Foundation, either version 3 of the License, or
! (at your option) any later version.
!
! This program is distributed in the hope that it will be useful,
! but WITHOUT ANY WARRANTY; without even the implied warranty of
! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
! GNU General Public License for more details.
!
! You should have received a copy of the GNU General Public License
! along with this program.  If not, see <http://www.gnu.org/licenses/>.

PROGRAM pic

  ! EPOCH2D is a Birdsall and Langdon type PIC code derived from the PSC
  ! written by Hartmut Ruhl.

  ! The particle pusher (particles.F90) and the field solver (fields.f90) are
  ! almost exact copies of the equivalent routines from PSC, modified slightly
  ! to allow interaction with the changed portions of the code and for
  ! readability. The MPI routines are exactly equivalent to those in PSC, but
  ! are completely rewritten in a form which is easier to extend with arbitrary
  ! fields and particle properties. The support code is entirely new and is not
  ! equivalent to PSC.

  ! EPOCH2D written by C.S.Brady, Centre for Fusion, Space and Astrophysics,
  ! University of Warwick, UK
  ! PSC written by Hartmut Ruhl

  USE balance
  USE deck
  USE diagnostics
  USE fields
  USE helper
  USE ic_module
  USE mpi_routines
  USE particles
  USE setup
  USE finish
  USE welcome
  USE window
  USE split_particle
  USE collisions
  USE particle_migration
  USE ionise
  USE calc_df
#ifdef PHOTONS
  USE photons
#endif
  USE injectors

  IMPLICIT NONE

  INTEGER :: ispecies, ierr
  LOGICAL :: halt = .FALSE., push = .TRUE.
  LOGICAL :: force_dump = .FALSE.
  CHARACTER(LEN=64) :: deck_file = 'input.deck'
  CHARACTER(LEN=*), PARAMETER :: data_dir_file = 'USE_DATA_DIRECTORY'
  CHARACTER(LEN=64) :: timestring
  REAL(num) :: runtime, dt_store
!zmeny
#if defined(PARTICLE_ID)
	INTEGER(i8), ALLOCATABLE :: my_ID(:)
#elif defined(PARTICLE_ID4)
        INTEGER(i4), ALLOCATABLE :: my_ID(:)
#endif
	INTEGER :: nop
	CHARACTER(LEN=64) :: list_of_particles = 'list.list'
	CHARACTER(LEN=64) :: nop_file = 'nop.list', line 
	LOGICAL :: res
	CHARACTER(LEN=64) :: filename
        REAL(num) :: dump_time, dump_time_orig
!end_zmeny 
  step = 0
  time = 0.0_num
#ifdef COLLISIONS_TEST
  ! used for testing
  CALL test_collisions
  STOP
#endif

  CALL mpi_minimal_init ! mpi_routines.f90
  real_walltime_start = MPI_WTIME()
  CALL minimal_init     ! setup.f90
  CALL get_job_id(jobid)
  CALL welcome_message  ! welcome.f90

  IF (rank == 0) THEN
    OPEN(unit=lu, status='OLD', file=TRIM(data_dir_file), iostat=ierr)
    IF (ierr == 0) THEN
      READ(lu,'(A)') data_dir
      CLOSE(lu)
      PRINT*, 'Using data directory "' // TRIM(data_dir) // '"'
    ELSE
      PRINT*, 'Specify output directory'
      READ(*,'(A)') data_dir
    END IF
    CALL cleanup_stop_files
  END IF

  CALL MPI_BCAST(data_dir, c_max_path_length, MPI_CHARACTER, 0, comm, errcode)

  ! version check only, exit silently
  IF (TRIM(data_dir) == 'VERSION_INFO') CALL finalise

  CALL register_objects ! custom.f90
  CALL read_deck(deck_file, .TRUE., c_ds_first)

  CALL setup_partlists  ! partlist.f90
  CALL timer_init

  IF (use_exact_restart) CALL read_cpu_split
  CALL setup_boundaries ! boundary.f90
  CALL mpi_initialise  ! mpi_routines.f90
  CALL after_control   ! setup.f90
  CALL open_files      ! setup.f90

!zmeny
  OPEN(unit=48, status = 'OLD', file=trim(data_dir) // '/' //list_of_particles)
  OPEN(unit=49, status = 'OLD', file=trim(data_dir) // '/' //nop_file)
  READ(49,*) nop
  READ(49,*) dump_time_orig
  dump_time = dump_time_orig
  CLOSE(49)
  ALLOCATE(my_ID(nop)) 
  READ(48,*) my_ID 
  CLOSE(48)
  IF (rank .EQ. 0) THEN
  WRITE(*,*) "Following particles will be tracked: ", my_ID
  WRITE(*,*) "At time: ", dump_time_orig
  END IF

   IF (rank == 0) THEN
     write (filename,"(A19,A4)") "//tracked_particles", ".txt"
     OPEN(unit=50, status='REPLACE', file=trim(data_dir) // trim(filename))
  END IF

  !end_zmeny

  ! Re-scan the input deck for items which require allocated memory
  CALL read_deck(deck_file, .TRUE., c_ds_last)
  CALL after_deck_last

  ! restart flag is set
  IF (ic_from_restart) THEN
    CALL restart_data(step)
  ELSE
    ! auto_load particles
    CALL auto_load
    time = 0.0_num
  END IF

  CALL custom_particle_load
  CALL manual_load
  CALL initialise_window ! window.f90
  CALL set_dt
  CALL set_maxwell_solver
  CALL deallocate_ic
  CALL update_particle_count

  npart_global = 0
  DO ispecies = 1, n_species
    npart_global = npart_global + species_list(ispecies)%count
  END DO

  ! .TRUE. to over_ride balance fraction check
  IF (npart_global > 0) CALL balance_workload(.TRUE.)

  IF (use_current_correction) CALL calc_initial_current
  CALL particle_bcs
  CALL efield_bcs

  IF (ic_from_restart) THEN
    IF (dt_from_restart > 0) dt = dt_from_restart
    time = time + dt / 2.0_num
    CALL update_eb_fields_final
    CALL moving_window
  ELSE
    dt_store = dt
    dt = dt / 2.0_num
    time = time + dt
    CALL bfield_final_bcs
    dt = dt_store
  END IF
  CALL count_n_zeros

  ! Setup particle migration between species
  IF (use_particle_migration) CALL initialise_migration

  IF (rank == 0) PRINT *, 'Equilibrium set up OK, running code'
#ifdef PHOTONS
  IF (use_qed) CALL setup_qed_module()
#endif

  walltime_started = MPI_WTIME()
  IF (.NOT.ic_from_restart) CALL output_routines(step) ! diagnostics.f90
  IF (use_field_ionisation) CALL initialise_ionisation

  IF (timer_collect) CALL timer_start(c_timer_step)

  DO
    IF ((step >= nsteps .AND. nsteps >= 0) &
        .OR. (time >= t_end) .OR. halt) EXIT

    IF (timer_collect) THEN
      CALL timer_stop(c_timer_step)
      CALL timer_reset
      timer_first(c_timer_step) = timer_walltime
    END IF

    push = (time >= particle_push_start_time)
#ifdef PHOTONS
    IF (push .AND. use_qed .AND. time > qed_start_time) THEN
      CALL qed_update_optical_depth()
    END IF
#endif

    CALL update_eb_fields_half
    IF (push) THEN
      CALL run_injectors
      ! .FALSE. this time to use load balancing threshold
      IF (use_balance) CALL balance_workload(.FALSE.)
!! zmeny
      
      CALL push_particles(my_ID, nop,dump_time)
      IF (time >= dump_time) THEN
      dump_time=dump_time+dump_time_orig
      END IF 
!! end_zmeny
      IF (use_particle_lists) THEN
        ! After this line, the particles can be accessed on a cell by cell basis
        ! Using the particle_species%secondary_list property
        CALL reorder_particles_to_grid

        ! call collision operator
        IF (use_collisions) THEN
          IF (use_collisional_ionisation) THEN
            CALL collisional_ionisation
          ELSE
            CALL particle_collisions
          END IF
        END IF

        ! Early beta version of particle splitting operator
        IF (use_split) CALL split_particles

        CALL reattach_particles_to_mainlist
      END IF
      IF (use_particle_migration) CALL migrate_particles(step)
      IF (use_field_ionisation) CALL ionise_particles
      CALL update_particle_count
    END IF

    CALL check_for_stop_condition(halt, force_dump)
    IF (halt) EXIT
    step = step + 1
    time = time + dt / 2.0_num
    CALL output_routines(step)
    time = time + dt / 2.0_num

    CALL update_eb_fields_final

    CALL moving_window
  END DO

  IF (rank == 0) runtime = MPI_WTIME() - walltime_started

#ifdef PHOTONS
  IF (use_qed) CALL shutdown_qed_module()
#endif

  CALL output_routines(step, force_dump)

  IF (rank == 0) THEN
    CALL create_full_timestring(runtime, timestring)
    WRITE(*,*) 'Final runtime of core = ' // TRIM(timestring)
  END IF

  CALL finalise

END PROGRAM pic
