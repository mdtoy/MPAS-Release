! Copyright (c) 2013,  Los Alamos National Security, LLC (LANS)
! and the University Corporation for Atmospheric Research (UCAR).
!
! Unless noted otherwise source code is licensed under the BSD license.
! Additional copyright and license information can be found in the LICENSE file
! distributed with this code, or at http://mpas-dev.github.com/license.html
!

!|||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
!
!  li_diagnostic_vars
!
!> \brief MPAS land ice module for calculating diagnostic variables
!> \author Matt Hoffman
!> \date   17 April 2011
!> \details
!>  This module contains various subroutines for
!>  calculating diagnostic (time-independent) variables
!>  for the land ice core.  
!>  These calculations should be general so as to be independent
!>  of time integration scheme.
!
!-----------------------------------------------------------------------

module li_diagnostic_vars

   use mpas_derived_types
   use mpas_pool_routines
   use mpas_timer
   use li_velocity
   use li_mask

   implicit none
   private

   !--------------------------------------------------------------------
   !
   ! Public parameters
   !
   !--------------------------------------------------------------------

   !--------------------------------------------------------------------
   !
   ! Public member functions
   !
   !--------------------------------------------------------------------
   public :: li_calculate_diagnostic_vars

   !--------------------------------------------------------------------
   !
   ! Private module variables
   !
   !--------------------------------------------------------------------



!***********************************************************************

contains

!***********************************************************************
!
!  routine li_calculate_diagnostic_vars
!
!> \brief   Calculates diagnostic variables 
!> \author  Matthew Hoffman
!> \date    12 September 2013
!> \details
!>  This routine calculates diagnostic variables using the current prognostic
!>  variables.  This is done in 3 parts:
!>  1. diagnostic solve part 1;  2. solve velocity;  3. diagnostic solve part 2
!>  Note: If the velocity solver requires an initial guess, it will be taken 
!>  from the timeLevel argument.  Therefore the normalVelocity in that time level
!>  should be updated with the guess prior to calling this subroutine, if necessary.
!
!-----------------------------------------------------------------------

   subroutine li_calculate_diagnostic_vars(domain, timeLevel, solveVelo, err)

      use mpas_vector_reconstruction

      !-----------------------------------------------------------------
      !
      ! input variables
      !
      !-----------------------------------------------------------------
      integer, intent(in) :: timeLevel  !< Input: Time level on which to calculate diagnostic variables
      logical, intent(in) :: solveVelo  !< Input: Whether or not to solve velocity

      !-----------------------------------------------------------------
      !
      ! input/output variables
      !
      !-----------------------------------------------------------------

      type (domain_type), intent(inout) :: domain  !< Input/Output: domain object

      !-----------------------------------------------------------------
      !
      ! output variables
      !
      !-----------------------------------------------------------------

      integer, intent(out) :: err !< Output: error flag

      !-----------------------------------------------------------------
      !
      ! local variables
      !
      !-----------------------------------------------------------------
      type (block_type), pointer :: block
      type (mpas_pool_type), pointer :: meshPool
      type (mpas_pool_type), pointer :: statePool
      real (kind=RKIND), dimension(:,:), pointer :: normalVelocity, uReconstructX, uReconstructY, uReconstructZ, uReconstructZonal, uReconstructMeridional
      integer :: err_tmp
!!!      integer :: blockVertexMaskChanged, procVertexMaskChanged, anyVertexMaskChanged


      err = 0

      ! ===
      ! === Diagnostic solve of variables prior to velocity 
      ! ===

      call mpas_timer_start("calc. diagnostic vars except vel")
      call diagnostic_solve_before_velocity(domain, timeLevel, err_tmp)  ! perhaps velocity solve should move in here.
      err = ior(err, err_tmp)
! This information is only needed for some external dycores.  This can be added back in when they are implemented.
! Should make this conditional to avoid unnecessary MPI comms.
!!!      block => domain % blocklist
!!!      do while (associated(block))
!!!         stateNew => block % state % time_levs(2) % state
!!!         stateOld => block % state % time_levs(1) % state
!!!         ! Determine if the vertex mask changed during this time step for this block (needed for LifeV)
!!!         ! \todo:  there may be some aspects of the mask that are ok change for LifeV, but for now just check the whole thing.
!!!         if ( sum(stateNew % vertexMask % array - stateOld % vertexMask % array) /= 0 ) then
!!!             blockVertexMaskChanged = 1
!!!         else
!!!             blockVertexMaskChanged = 0
!!!         endif
!!!         !print *, 'blockVertexMaskChanged ', blockVertexMaskChanged

!!!         ! Determine if any blocks on this processor had a change to the vertex mask
!!!         procVertexMaskChanged = max(procVertexMaskChanged, blockVertexMaskChanged)

!!!         block => block % next
!!!      end do
!!!       
!!!      ! Determine if the vertex mask has changed on any processor (need to exit the block loop to do so)
!!!      call mpas_dmpar_max_int(dminfo, procVertexMaskChanged, anyVertexMaskChanged)

      call mpas_timer_stop("calc. diagnostic vars except vel")



      ! ===
      ! === Diagnostic solve of velocity 
      ! ===
      if (solveVelo) then
          call mpas_timer_start("velocity solve")

          ! TODO Once multiple blocks are supported, this section will need to change.
          ! LifeV does not support multiple blocks but the MPAS SIA could.
          block => domain % blocklist
          do while (associated(block))
             call mpas_pool_get_subpool(block % structs, 'mesh', meshPool)
             call mpas_pool_get_subpool(block % structs, 'state', statePool)

!!!             ! Assign the vertex-changed flag to each block
!!!             stateNew % anyVertexMaskChanged % scalar = anyVertexMaskChanged
!!!             !print *, 'anyVertexMaskChanged: ', anyVertexMaskChanged

             call li_velocity_solve(meshPool, statePool, timeLevel, err_tmp)    ! ****** Calculate Velocity ******
             err = ior(err, err_tmp)

             block => block % next
          end do

          ! update halos on velocity
          call mpas_timer_start("halo updates")
          call mpas_dmpar_field_halo_exch(domain, 'normalVelocity', timeLevel=timeLevel)
          call mpas_timer_stop("halo updates")

          call mpas_timer_stop("velocity solve")
      endif


      ! ===
      ! === Diagnostic solve of variables after velocity 
      ! ===

      call mpas_timer_start("calc. diagnostic vars except vel")

      ! Calculate reconstructed velocities 
      ! do this after velocity halo update in case velocities on the 1-halo edge are wrong (depends on velocity solver)
      ! Still do this even if we didn't calculate velocity because on a restart these will be defined at the initial time.
      block => domain % blocklist
      do while (associated(block))
         call mpas_pool_get_subpool(block % structs, 'mesh', meshPool)
         call mpas_pool_get_subpool(block % structs, 'state', statePool)

         call mpas_pool_get_array(statePool, 'normalVelocity', normalVelocity, timeLevel=timeLevel)
         call mpas_pool_get_array(statePool, 'uReconstructX', uReconstructX, timeLevel=timeLevel)
         call mpas_pool_get_array(statePool, 'uReconstructY', uReconstructY, timeLevel=timeLevel)
         call mpas_pool_get_array(statePool, 'uReconstructZ', uReconstructZ, timeLevel=timeLevel)
         call mpas_pool_get_array(statePool, 'uReconstructZonal', uReconstructZonal, timeLevel=timeLevel)
         call mpas_pool_get_array(statePool, 'uReconstructMeridional', uReconstructMeridional, timeLevel=timeLevel)

         call mpas_reconstruct(meshPool, normalVelocity,               &
                          uReconstructX, uReconstructY, uReconstructZ, &
                          uReconstructZonal, uReconstructMeridional )

         block => block % next
      end do


      block => domain % blocklist
      do while (associated(block))
         call mpas_pool_get_subpool(block % structs, 'mesh', meshPool)
         call mpas_pool_get_subpool(block % structs, 'state', statePool)
         call diagnostic_solve_after_velocity(meshPool, statePool, timeLevel, err)  ! Some diagnostic variables require velocity to compute
         err = ior(err, err_tmp)

         block => block % next
      end do

      call mpas_timer_start("halo updates")
      call mpas_dmpar_field_halo_exch(domain, 'layerThicknessEdge', timeLevel=timeLevel)
      call mpas_timer_stop("halo updates")

      call mpas_timer_stop("calc. diagnostic vars except vel")

      ! === error check and exit
      if (err == 1) then
          print *, "An error has occurred in li_calculate_diagnostic_vars. Aborting..."
          !call mpas_dmpar_abort(dminfo)
      endif

   !--------------------------------------------------------------------
   end subroutine li_calculate_diagnostic_vars




!***********************************************************************
!***********************************************************************
! Private subroutines:
!***********************************************************************
!***********************************************************************


!***********************************************************************
!
!  subroutine diagnostic_solve_before_velocity
!
!> \brief   Computes diagnostic variables prior to velocity
!> \author  Matt Hoffman
!> \date    19 April 2012
!> \details 
!> This routine computes the diagnostic variables for land ice
!> that are needed before velocity is solved.
!
!-----------------------------------------------------------------------
   subroutine diagnostic_solve_before_velocity(domain, timeLevel, err)!{{{

      !-----------------------------------------------------------------
      !
      ! input variables
      !
      !-----------------------------------------------------------------
      integer, intent(in) :: timeLevel  !< Input: Time level on which to calculate diagnostic variables

      !-----------------------------------------------------------------
      !
      ! input/output variables
      !
      !-----------------------------------------------------------------

      type (domain_type), intent(inout) :: &
         domain         !< Input/Output: Domain object

      !-----------------------------------------------------------------
      !
      ! output variables
      !
      !-----------------------------------------------------------------

      integer, intent(out) :: err !< Output: error flag

      !-----------------------------------------------------------------
      !
      ! local variables
      !
      !-----------------------------------------------------------------
      type (block_type), pointer :: block
      type (mpas_pool_type), pointer :: meshPool
      type (mpas_pool_type), pointer :: statePool
      real (kind=RKIND), dimension(:), pointer :: thickness, upperSurface, &
        lowerSurface, bedTopography, upperSurfaceVertex
      integer, dimension(:), pointer :: cellMask
      real (kind=RKIND), dimension(:,:), pointer :: layerThickness
      real (kind=RKIND), dimension(:,:,:), pointer :: tracers
      integer, pointer :: nCells
      real (kind=RKIND), pointer :: config_sea_level, config_ice_density, config_ocean_density
      real (kind=RKIND) :: thisThk
      integer :: iCell, iLevel
      integer :: err_tmp


      err = 0
      err_tmp = 0

      block => domain % blocklist
      do while (associated(block))
         ! Mesh information
         call mpas_pool_get_subpool(block % structs, 'mesh', meshPool)
         call mpas_pool_get_subpool(block % structs, 'state', statePool)

         ! Calculate masks - needs to happen before calculating lower surface so we know where the ice is floating
         call li_calculate_mask(meshPool, statePool, timeLevel, err_tmp)
         err = ior(err, err_tmp)

         block => block % next
      end do

      ! Update halos on masks - the outermost cells/edges/vertices may be wrong for mask components that need neighbor information
      call mpas_timer_start("halo updates")
      call mpas_dmpar_field_halo_exch(domain, 'cellMask', timeLevel=timeLevel)
      call mpas_dmpar_field_halo_exch(domain, 'edgeMask', timeLevel=timeLevel)
      call mpas_dmpar_field_halo_exch(domain, 'vertexMask', timeLevel=timeLevel)
      call mpas_timer_stop("halo updates")

!!!      ! Update beta before the velocity solve occurs, now that we have the new state and its mask.
!!!      !    It's ok to overwrite the beta values with 0's here, because each time step
!!!      !    we get a fresh copy of the array from the annual_forcing subroutine.
!!!      !    Note: some velocity solvers may do this on their own, but we are doing it here for completeness.
!!!      where ( MASK_IS_FLOATING(cellMask) )
!!!         beta = 0.0_RKIND
!!!      end where

!!!      ! Give non-ice cells a temperature of 0
!!!      do iCell = 1, nCells
!!!         if ( MASK_IS_NOT_ICE(cellMask(iCell)) ) then
!!!            state % tracers % array( state%index_temperature, :, iCell) = 0.0_RKIND
!!!         end if
!!!      end do

      block => domain % blocklist
      do while (associated(block))
          call mpas_pool_get_subpool(block % structs, 'mesh', meshPool)
          call mpas_pool_get_subpool(block % structs, 'state', statePool)

          call mpas_pool_get_dimension(meshPool, 'nCells', nCells)

          call mpas_pool_get_config(liConfigs, 'config_sea_level', config_sea_level)
          call mpas_pool_get_config(liConfigs, 'config_ice_density', config_ice_density)
          call mpas_pool_get_config(liConfigs, 'config_ocean_density', config_ocean_density)

          call mpas_pool_get_array(statePool, 'cellMask', cellMask, timeLevel=timeLevel)
          call mpas_pool_get_array(statePool, 'thickness', thickness, timeLevel=timeLevel)
          call mpas_pool_get_array(statePool, 'upperSurface', upperSurface, timeLevel=timeLevel)
          call mpas_pool_get_array(statePool, 'upperSurfaceVertex', upperSurfaceVertex, timeLevel=timeLevel)
          call mpas_pool_get_array(statePool, 'lowerSurface', lowerSurface, timeLevel=timeLevel)
          call mpas_pool_get_array(statePool, 'layerThickness', layerThickness, timeLevel=timeLevel)
          call mpas_pool_get_array(statePool, 'tracers', tracers, timeLevel=timeLevel)
          call mpas_pool_get_array(meshPool, 'bedTopography', bedTopography)

          ! Lower surface is based on floatation for floating ice.  For grounded ice (and non-ice areas) it is the bed.
          where ( li_mask_is_floating_ice(cellMask) )
             lowerSurface = config_sea_level - thickness * (config_ice_density / config_ocean_density)
          elsewhere
             lowerSurface = bedTopography
          end where
          ! Make sure lowerSurface calculation is reasonable.  This check could be deleted once this has been throroughly tested.
          do iCell = 1, nCells
             if (lowerSurface(iCell) < bedTopography(iCell)) then
                write (0,*) 'lowerSurface less than bedTopography at cell:', iCell
                err = 1
             endif
          end do

          ! Upper surface is the lower surface plus the thickness
          upperSurface(:) = lowerSurface(:) + thickness(:)
          call cells_to_vertices_2dfield(meshPool, upperSurface, upperSurfaceVertex)  ! (Needed only for SIA solver)
          ! Note: the outer halo may be wrong, but that's ok as long as numhalos>1 because the velocity on the 0-halo will still be correct.

          ! Do vertical remapping of layerThickness and tracers
          call vertical_remap(thickness, cellMask, meshPool, layerThickness, tracers, err)
          err = ior(err, err_tmp)

          block => block % next
      end do


      ! === error check
      if (err > 0) then
          write (0,*) "An error has occurred in diagnostic_solve_before_velocity."
      endif

   !--------------------------------------------------------------------
   end subroutine diagnostic_solve_before_velocity



!***********************************************************************
!
!  subroutine diagnostic_solve_after_velocity
!
!> \brief   Computes diagnostic variables that require knowing velocity
!> \author  Matt Hoffman
!> \date    19 April 2012
!> \details 
!> This routine computes the diagnostic variables that require knowing velocity for land ice
!
!-----------------------------------------------------------------------
   subroutine diagnostic_solve_after_velocity(meshPool, statePool, timeLevel, err)

      !-----------------------------------------------------------------
      !
      ! input variables
      !
      !-----------------------------------------------------------------
      type (mpas_pool_type), intent(in) :: &
         meshPool          !< Input: mesh information

      integer, intent(in) :: timeLevel  !< Input: Time level on which to calculate diagnostic variables

      !-----------------------------------------------------------------
      !
      ! input/output variables
      !
      !-----------------------------------------------------------------
      type (mpas_pool_type), intent(inout) :: &
         statePool         !< Input/Output: state for which to update diagnostic variables

      !-----------------------------------------------------------------
      !
      ! output variables
      !
      !-----------------------------------------------------------------
      integer, intent(out) :: err !< Output: error flag

      !-----------------------------------------------------------------
      !
      ! local variables
      !
      !-----------------------------------------------------------------
      real (kind=RKIND), dimension(:,:), pointer :: layerThickness, layerThicknessEdge, normalVelocity
      integer, dimension(:,:), pointer :: cellsOnEdge
      integer, pointer :: nEdges, nVertLevels
      character (len=StrKIND), pointer :: config_thickness_advection
      integer :: iEdge, cell1, cell2, k
      real (kind=RKIND) :: VelSign

      err = 0

      call mpas_pool_get_dimension(meshPool, 'nEdges', nEdges)
      call mpas_pool_get_dimension(meshPool, 'nVertLevels', nVertLevels)
      call mpas_pool_get_array(meshPool, 'cellsOnEdge', cellsOnEdge)

      call mpas_pool_get_config(liConfigs, 'config_thickness_advection', config_thickness_advection)

      call mpas_pool_get_array(statePool, 'layerThickness', layerThickness, timeLevel=timeLevel)
      call mpas_pool_get_array(statePool, 'layerThicknessEdge', layerThicknessEdge, timeLevel=timeLevel)
      call mpas_pool_get_array(statePool, 'normalVelocity', normalVelocity, timeLevel=timeLevel)

      ! Calculate h_edge.  This is used by both thickness and tracer advection on the following Forward Euler time step.  
      ! Note: FO-Upwind thickness advection does not explicitly use h_edge but a FO h_edge is implied.
      ! Note: SIA velocity solver uses its own local calculation of h_edge that is always 2nd order.
      ! Note: ocn_diagnostic_solve in mpas_ocn_tendency.F has 2, 3, & 4th order calculations for h_edge that can be used.  
      ! NOTE: This calculates FO upwind h edge

      ! Both thickness and layerThickness should be updated by this time.
      if (config_thickness_advection == 'fo') then
         ! If using FO-Upwind then h_edge must be FO.
         do iEdge=1,nEdges
            cell1 = cellsOnEdge(1,iEdge)
            cell2 = cellsOnEdge(2,iEdge)
            do k=1, nVertLevels
               ! Calculate h on edges using first order
               VelSign = sign(1.0_RKIND, normalVelocity(k, iEdge))
               layerThicknessEdge(k,iEdge) = max(VelSign * layerThickness(k, cell1), VelSign * (-1.0_RKIND) * layerThickness(k, cell2)) 
               ! + velocity goes from index 1 to 2 in the cellsOnEdge array.  
               !  Doug does the calculation as: h_edge = max(VelSign, 0.0) * h1 - min(VelSign, 0.0) * h2
               !!! ! Calculate h on edges using second order
               !!! layerThicknessEdge(k,iEdge) = 0.5_RKIND * (layerThickness(k, cell1) + layerThickness(k, cell2))
            end do
            ! thickness_edge is not currently in registry and not currenly needed.  If it is, uncomment the next line
            !h_edge = max(thickness(cell1), thickness(cell2))
            !!!h_edge = (thickness(k) + thickness(k) ) / 2.0  ! 2nd order 
         end do
      else
          !write(6,*) 'layerThicknessEdge not calculated!'
      endif

      ! Note: the outmost layerThicknessEdge may be wrong if its upwind cell is off this block - halo update should be done if this variable will be used.

   end subroutine diagnostic_solve_after_velocity



!***********************************************************************
!
!  subroutine vertical_remap_cism_loops
!
!> \brief   Vertical remapping of thickness and tracers
!> \author  Matt Hoffman
!> \date    06 February 2013
!> \details 
!>  This routine performs vertical remapping of thickness and tracers from one vertical
!>  coordinate system to another, as is required for our sigma coordinate system.  
!>  The remapping is first-order accurate.
!>  This uses code from the CISM glissade_transport.F90 module written by Bill Lipscomb.  
!>  I have altered the array structures to work with MPAS.  Indexing/looping order is a bit
!>  of a hodgepodge at the moment and should be optimized.
!>
!>  NOTE: This version (with _cism_loops suffix) uses the looping with minimal changes
!>  from the CISM code.  The other version has been refactored to be more efficient
!>  for MPAS.  This version is intended to be deleted once tracer advection is
!>  added to the model and the two versions can be compared.  (I can't test the new
!>  version until tracer advection exists!)
!
!-----------------------------------------------------------------------
   subroutine vertical_remap_cism_loops(layerThickness, thickness, tracers, meshPool, err)
      !-----------------------------------------------------------------
      !
      ! input variables
      !
      !-----------------------------------------------------------------

      real (kind=RKIND), dimension(:), intent(in) :: &
         thickness    !< Input: 

      type (mpas_pool_type), intent(in) :: &
         meshPool          !< Input: mesh information

      !-----------------------------------------------------------------
      !
      ! input/output variables
      !
      !-----------------------------------------------------------------

      real (kind=RKIND), dimension(:,:), intent(inout) :: &
         layerThickness    !< Input:

      real (kind=RKIND), dimension(:,:,:), intent(inout) :: &
         tracers    !< Input:

      !-----------------------------------------------------------------
      !
      ! output variables
      !
      !-----------------------------------------------------------------

      integer, intent(out) :: err !< Output: error flag

      !-----------------------------------------------------------------
      !
      ! local variables
      !
      !-----------------------------------------------------------------
      ! pointers to mesh arrays
      real (kind=RKIND), dimension(:), pointer :: layerThicknessFractions, layerInterfaceSigma
      ! local arrays
      real (kind=RKIND), dimension(:), allocatable :: recipThickness
      real (kind=RKIND), dimension(:,:), allocatable :: layerInterfaceSigma_Input
      real (kind=RKIND), dimension(:,:,:), allocatable :: hTsum
      ! counters, mesh variables, index variables
      integer, pointer :: nCells, nVertLevels
      integer :: nTracers, iCell, k, k1, k2, nt
      ! stuff for making calculations
      real(kind=RKIND) :: thisThk, zhi, zlo, hOverlap

      err = 0

      call mpas_pool_get_dimension(meshPool, 'nCells', nCells)
      call mpas_pool_get_dimension(meshPool, 'nVertLevels', nVertLevels)
      nTracers = size(tracers, 1)

      call mpas_pool_get_array(meshPool, 'layerThicknessFractions', layerThicknessFractions)
      call mpas_pool_get_array(meshPool, 'layerInterfaceSigma', layerInterfaceSigma)

      allocate(recipThickness(nCells+1))
      allocate(layerInterfaceSigma_Input(nVertLevels+1, nCells+1))
      allocate(hTsum(nCells+1, nTracers, nVertLevels))

      ! *** Calculate reciprocal thickness so we don't divide by 0
      where (thickness > 0.0_RKIND)
         recipThickness = 1.0_RKIND / thickness
      elsewhere
         recipThickness = 0.0_RKIND
      end where

      ! *** Calculate vertical sigma coordinates of each layer interface for the input non-sigma state and desired new sigma-based state (we already have that as mesh % layerInterfaceSigma)
      layerInterfaceSigma_Input(1,:) = 0.0_RKIND 
      do k = 2, nVertLevels
        layerInterfaceSigma_Input(k,:) = layerInterfaceSigma_Input(k-1,:) + layerThickness(k-1,:) * recipThickness(:)
      end do
      layerInterfaceSigma_Input(nVertLevels+1,:) = 1.0_RKIND 

      ! *** Compute new layer thicknesses (layerInterfaceSigma coordinates)
      do iCell = 1, nCells
         thisThk = thickness(iCell)
         do k = 1, nVertLevels
           layerThickness(k,iCell) = layerThicknessFractions(k) * thisThk
         end do
         ! Check for conservation of mass.  Put any residual in the top layer.
         layerThickness(1,iCell) = layerThickness(1,iCell) + (thisThk - sum(layerThickness(:,iCell)) )
      end do
      ! TODO This conservation check may make layerThicknesses inconsistent with the sigma levels (which are used below in tracer remapping.

       !-----------------------------------------------------------------
       ! Compute sum of h*T for each new layer (k2) by integrating
       ! over the regions of overlap with old layers (k1).
       ! Note: It might be worth trying a more efficient
       !       search algorithm if the number of layers is large.
       !       This algorithm scales as nlyr^2.
       !       Also, may want to rearrange loop order if there are many tracers.
       !-----------------------------------------------------------------

       do k2 = 1, nVertLevels
          hTsum(:,:,k2) = 0.d0 
          do k1 = 1, nVertLevels
             do nt = 1, nTracers
                do iCell = 1, nCells
                      zhi = min (layerInterfaceSigma_Input(k1+1,iCell), layerInterfaceSigma(k2+1)) 
                      zlo = max (layerInterfaceSigma_Input(k1,iCell), layerInterfaceSigma(k2))
                      hOverlap = max (zhi-zlo, 0.0_RKIND) * thickness(iCell)
                      hTsum(iCell,nt,k2) = htsum(iCell,nt,k2)    &
                                       +  tracers(nt,k1,iCell) * hOverlap
                enddo      ! iCell
             enddo         ! nt
          enddo            ! k1
       enddo               ! k2
 
       !-----------------------------------------------------------------
       ! Compute tracer values in new layers
       !-----------------------------------------------------------------
 
       do k = 1, nVertLevels
          do nt = 1, nTracers
                do iCell = 1, nCells
                   if (layerThickness(k, iCell) > 0.0_RKIND) then
                      tracers(nt,k,iCell) = hTsum(iCell,nt,k) / layerThickness(k, iCell)
                   else
                      tracers(nt,k,iCell) = 0.0_RKIND
                   endif
                enddo   ! iCell
          enddo         ! nt
       enddo            ! k

      deallocate(recipThickness)
      deallocate(layerInterfaceSigma_Input)
      deallocate(hTsum)

   end subroutine vertical_remap_cism_loops




!***********************************************************************
!
!  subroutine vertical_remap
!
!> \brief   Vertical remapping of thickness and tracers
!> \author  Matt Hoffman
!> \date    02 October 2013
!> \details 
!>  This routine performs vertical remapping of thickness and tracers from one vertical
!>  coordinate system to another, as is required for our sigma coordinate system.
!>  The remapping is first-order accurate.
!>  This uses code from the CISM glissade_transport.F90 module written by Bill Lipscomb.
!>  I have altered the array structures to work with MPAS and refactored it.
!>  It now does all calculations column-wise, so it can be vectorized using
!>  OpenMP over either blocks or cells.
!>  I have dealt with 0 thickness in non-ice cells using eps and the cellMask,
!>  rather than using if/where-statements.
!
!-----------------------------------------------------------------------
   subroutine vertical_remap(thickness, cellMask, meshPool, layerThickness, tracers, err)

      !-----------------------------------------------------------------
      !
      ! input variables
      !
      !-----------------------------------------------------------------

      real (kind=RKIND), dimension(:), intent(in) :: &
         thickness    !< Input: ice thickness (already updated)

      integer, dimension(:), intent(in) :: &
         cellMask    !< Input: mask for cells (needed for determining presence/absence of ice)

      type (mpas_pool_type), intent(in) :: &
         meshPool          !< Input: mesh information

      !-----------------------------------------------------------------
      !
      ! input/output variables
      !
      !-----------------------------------------------------------------

      real (kind=RKIND), dimension(:,:), intent(inout) :: &
         layerThickness    !< Input/Output: thickness of layers (to be updated)

      real (kind=RKIND), dimension(:,:,:), intent(inout) :: &
         tracers    !< Input/Output: tracer values (to be updated)

      !-----------------------------------------------------------------
      !
      ! output variables
      !
      !-----------------------------------------------------------------

      integer, intent(out) :: err !< Output: error flag

      !-----------------------------------------------------------------
      !
      ! local variables
      !
      !-----------------------------------------------------------------
      ! pointers to mesh arrays
      real (kind=RKIND), dimension(:), pointer :: layerThicknessFractions, layerInterfaceSigma
      ! local arrays
      real (kind=RKIND), dimension(:), allocatable :: layerInterfaceSigma_Input
      real (kind=RKIND), dimension(:,:), allocatable :: hTsum
      ! counters, mesh variables, index variables
      integer, pointer :: nCells, nVertLevels
      integer :: nTracers, iCell, k, k1, k2, nt
      ! stuff for making calculations
      real(kind=RKIND) :: thisThk, zhi, zlo, hOverlap
      real(kind=RKIND), parameter :: eps = 1.0d-30  ! Make a tiny value so we don't corrupt any cells with ice

      err = 0

      call mpas_pool_get_dimension(meshPool, 'nCells', nCells)
      call mpas_pool_get_dimension(meshPool, 'nVertLevels', nVertLevels)
      nTracers = size(tracers, 1)

      call mpas_pool_get_array(meshPool, 'layerThicknessFractions', layerThicknessFractions)
      call mpas_pool_get_array(meshPool, 'layerInterfaceSigma', layerInterfaceSigma)

      allocate(layerInterfaceSigma_Input(nVertLevels+1))
      allocate(hTsum(nTracers, nVertLevels))

      do iCell = 1, nCells  ! Do all calculations column-wise

         thisThk = thickness(iCell)

         ! *** Calculate vertical sigma coordinates of each layer interface for the input non-sigma state 
         !     (we already have the desired new sigma-based state as mesh % layerInterfaceSigma)
         layerInterfaceSigma_Input(1) = 0.0_RKIND
         do k = 2, nVertLevels
            layerInterfaceSigma_Input(k) = layerInterfaceSigma_Input(k-1) + layerThickness(k-1, iCell) / (thisThk + eps)
            ! Note: including eps to avoid divide by 0, but need to mask out cells with no ice below in calculating
            !       layerThickness and tracer values.
         end do
         layerInterfaceSigma_Input(nVertLevels+1) = 1.0_RKIND

         ! *** Compute new layer thicknesses (layerInterfaceSigma coordinates)

         do k = 1, nVertLevels
            layerThickness(k,iCell) = layerThicknessFractions(k) * (thisThk + eps)
            ! Note: layerThickness will have garbage values in non-ice cells due to eps
         end do
         ! Check for conservation of mass.  Put any residual in the top layer.
         layerThickness(1,iCell) = layerThickness(1,iCell) + (thisThk - sum(layerThickness(:,iCell)) )
         ! TODO This conservation check may make layerThicknesses inconsistent with the sigma levels (which are used below in tracer remapping.

         !-----------------------------------------------------------------
         ! Compute sum of h*T for each new layer (k2) by integrating
         ! over the regions of overlap with old layers (k1).
         ! Note: It might be worth trying a more efficient
         !       search algorithm if the number of layers is large.
         !       This algorithm scales as nlyr^2.
         !-----------------------------------------------------------------

         do k2 = 1, nVertLevels
            hTsum(:,k2) = 0.d0
            do k1 = 1, nVertLevels
               do nt = 1, nTracers
                  zhi = min (layerInterfaceSigma_Input(k1+1), layerInterfaceSigma(k2+1))
                  zlo = max (layerInterfaceSigma_Input(k1), layerInterfaceSigma(k2))
                  hOverlap = max (zhi-zlo, 0.0_RKIND) * thisThk
                  hTsum(nt,k2) = htsum(nt,k2) + tracers(nt,k1,iCell) * hOverlap
               enddo         ! nt
            enddo            ! k1
         enddo               ! k2

         !-----------------------------------------------------------------
         ! Compute tracer values in new layers
         !-----------------------------------------------------------------

         do k = 1, nVertLevels
            do nt = 1, nTracers
               tracers(nt,k,iCell) = hTsum(nt,k) / layerThickness(k, iCell) * real(li_mask_is_ice_int(cellMask(iCell)), RKIND)
               layerThickness(k,iCell) = layerThickness(k,iCell) * real(li_mask_is_ice_int(cellMask(iCell)), RKIND)
               ! Note: the last term is used to multiply by 0 where there is no ice in order to clear out garbage introduced by eps
            enddo         ! nt
         enddo            ! k

      enddo ! nCells


      deallocate(layerInterfaceSigma_Input)
      deallocate(hTsum)

   end subroutine vertical_remap



!***********************************************************************
!
!  subroutine cells_to_vertices_2dfield
!
!> \brief   Converts a 2d scalar field from cells to vertices
!> \author  Matt Hoffman
!> \date    21 May 2012
!> \details 
!>  This routine converts a 2d scalar field from cells to vertices.
!-----------------------------------------------------------------------
   subroutine cells_to_vertices_2dfield(meshPool, fieldCells, fieldVertices)
      !-----------------------------------------------------------------
      !
      ! input variables
      !
      !-----------------------------------------------------------------

      type (mpas_pool_type), intent(in) :: &
         meshPool          !< Input: mesh information
      real (kind=RKIND), dimension(:), intent(in) :: &
         fieldCells    !< Input: field on cells

      !-----------------------------------------------------------------
      !
      ! input/output variables
      !
      !-----------------------------------------------------------------

      !-----------------------------------------------------------------
      !
      ! output variables
      !
      !-----------------------------------------------------------------

      real (kind=RKIND), dimension(:), intent(out) :: &
         fieldVertices    !< Input: field on vertices

      !-----------------------------------------------------------------
      !
      ! local variables
      !
      !-----------------------------------------------------------------
      real (kind=RKIND), dimension(:,:), pointer :: kiteAreasOnVertex
      integer, dimension(:,:), pointer :: cellsOnVertex
      integer, pointer :: nVertices, vertexDegree
      integer :: iCell, icell2, iVertex, cellIndex
      real (kind=RKIND) :: fVertexAccum, baryweight, weightAccum

      ! Get needed items from mesh pool
      call mpas_pool_get_dimension(meshPool, 'nVertices', nVertices)
      call mpas_pool_get_dimension(meshPool, 'vertexDegree', vertexDegree)

      call mpas_pool_get_array(meshPool, 'kiteAreasOnVertex', kiteAreasOnVertex)
      call mpas_pool_get_array(meshPool, 'cellsOnVertex', cellsOnVertex)

      ! Calculate h on vertices using barycentric interpolation
      do iVertex = 1, nVertices  ! Loop over vertices
        fVertexAccum = 0.0_RKIND
        weightAccum = 0.0_RKIND
        ! Loop over cells on this vertex
        do iCell = 1, vertexDegree
          cellIndex = cellsOnVertex(iCell, iVertex)
          baryweight = 0.0_RKIND
          do iCell2 = 1, vertexDegree
            if (iCell2 /= icell) baryweight = baryweight + 0.5 * kiteAreasOnVertex(iCell2, iVertex)
          enddo
          fVertexAccum = fVertexAccum + baryweight * fieldCells(cellIndex)  ! add the contribution from this cell's kite
          weightAccum = weightAccum + kiteAreasOnVertex(iCell, iVertex)  ! This doesn't match areaTriangle for some weird vertices
        enddo
        fieldVertices(iVertex) = fVertexAccum / weightAccum  ! I assume this should never be 0...
      enddo

   end subroutine cells_to_vertices_2dfield

end module li_diagnostic_vars

