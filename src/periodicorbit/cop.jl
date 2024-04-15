struct COPCACHE{𝒯, TL, TU, Tp}
    blockⱼ::Matrix{𝒯}
    blockₙ::Matrix{𝒯}
    blockₙ₂::Matrix{𝒯}
    Lₜ::TL
    Uₜ::TU
    last_row_𝐅𝐬⁻¹_analytical::Matrix{𝒯}
    last_row_𝐅𝐬::Matrix{𝒯}
    Jcoll::Matrix{𝒯}
    Jext::Matrix{𝒯}
    coll::Tp
    p::Vector{Vector{Int}}

    function COPCACHE(coll::PeriodicOrbitOCollProblem, δn = 0)
        N, m, Ntst = size(coll)
        n = N
        nbcoll = n * m
        Npo = length(coll) + 1
        𝒯 = eltype(coll)

        blockⱼ = zeros(𝒯, nbcoll+1+δn, nbcoll)
        blockₙ = zeros(𝒯, nbcoll, n)
        blockₙ₂ = copy(blockₙ)

        Lₜ = LowerTriangular(zeros(𝒯, nbcoll, nbcoll))
        Uₜ = UpperTriangular(zeros(𝒯, nbcoll, nbcoll))

        Jcoll_tmp = zeros(𝒯, Npo+δn, Npo+δn)
        Jext_tmp= zeros(𝒯, Ntst*N+N+1+δn, Ntst*N+N+1+δn)

        nⱼ = size(Jcoll_tmp, 1)
        last_row_𝐅𝐬⁻¹_analytical = zeros(𝒯, δn + 1, nⱼ) # last row of 𝐅𝐬⁻¹
        last_row_𝐅𝐬 = zeros(𝒯, δn + 1, nⱼ)              # last row of 𝐅𝐬

        # vector to hold the permutations
        p = [1:Ntst|>collect for _=1:Ntst]

        new{𝒯, typeof(Lₜ), typeof(Uₜ), typeof(coll)}(blockⱼ,
                                                    blockₙ,
                                                    blockₙ₂,
                                                    Lₜ,
                                                    Uₜ,
                                                    last_row_𝐅𝐬⁻¹_analytical,
                                                    last_row_𝐅𝐬,
                                                    Jcoll_tmp,
                                                    Jext_tmp,
                                                    coll,
                                                    p)
    end
end

struct COPLS{𝒯, TL} <: AbstractDirectLinearSolver
    cache::COPCACHE{𝒯, TL}
end

struct COPBLS{𝒯, TL, Ts, Tj} <: AbstractBorderedLinearSolver
    cache::COPCACHE{𝒯, TL}
    solver::Ts
    J::Tj
end

COPLS(coll::PeriodicOrbitOCollProblem) = COPLS(COPCACHE(coll))
COPBLS(coll::PeriodicOrbitOCollProblem; use_lu_for_jext = false) = COPBLS(COPCACHE(coll, 1), nothing, nothing)
COPLS(;use_lu_for_jext = false) = COPLS(PeriodicOrbitOCollProblem(2,2;N=0))
COPBLS(;use_lu_for_jext = false) = COPBLS(PeriodicOrbitOCollProblem(2,2;N=0))

# inplace version of LinearAlgebra.ipiv2perm
function _ipiv2perm!(p, v, maxi::Integer)
    LinearAlgebra.require_one_based_indexing(v)
    p .= 1:maxi
    @inbounds for i in 1:length(v)
        p[i], p[v[i]] = p[v[i]], p[i]
    end
    return p
end

function _invperm!(b, a::AbstractVector)
    LinearAlgebra.require_one_based_indexing(a)
    b .= 0 # similar vector of zeros
    n = length(a)
    @inbounds for (i, j) in enumerate(a)
        ((1 <= j <= n) && b[j] == 0) ||
            throw(ArgumentError("argument is not a permutation"))
        b[j] = i
    end
    b
end

@views function solve_cop(coll::PeriodicOrbitOCollProblem, J, rhs0, cop_cache; _DEBUG::Bool = false, USELU = false)
    @assert size(J, 1) == size(J, 2) == length(rhs0) "The right hand side does not have the right dimension or the jacobian is not square. \nsize(J) = $(size(J)) and \nlength(rhs0) = $(length(rhs0))\n"
    N, m, Ntst = size(coll)
    nbcoll = N * m
    # size of the periodic orbit problem.
    # We use this to tackle the case where size(J, 1) > Nₚₒ
    Npo = length(coll) + 1
    nⱼ = size(J, 1)
    δn =  nⱼ - Npo # this allows to compute the border side
    @assert δn >= 0

    # matrix to contain the linear system for the external variables
    Jext = cop_cache.Jext
    @assert size(Jext, 1) == size(Jext, 2) == (Ntst+1)*N+1+δn "Error with matrix of external variables. Please report this issue on the website of BifurcationKit.\nδn = $δn\nsize(Jext) = $(size(Jext))"
    𝒯 = eltype(coll)
    In = I(N)

    if _DEBUG
        P = Matrix{𝒯}(LinearAlgebra.I(nⱼ))
        Jtmp = zeros(𝒯, nbcoll + δn + 1, nbcoll)
    end

    rhs = condensation_of_parameters!(cop_cache, coll, J, In, rhs0)
    Jcond = cop_cache.Jcoll

    if _DEBUG
        Fₚ = lu(P); Jcond = Fₚ \ J; rhs = Fₚ \ rhs0
    end

    # last_row_𝐅𝐬⁻¹_analytical = zeros(𝒯, δn + 1, nⱼ) # last row of 𝐅𝐬⁻¹
    # last_row_𝐅𝐬 = zeros(𝒯, δn + 1, nⱼ) # last row of 𝐅𝐬
    @unpack last_row_𝐅𝐬⁻¹_analytical,
            last_row_𝐅𝐬 = cop_cache

    if δn == 0 
        d = dot(last_row_𝐅𝐬⁻¹_analytical, 
                J[eachindex(last_row_𝐅𝐬⁻¹_analytical), end]) +
                J[end, end]
        rhs[end] = dot(last_row_𝐅𝐬⁻¹_analytical, 
                rhs0[eachindex(last_row_𝐅𝐬⁻¹_analytical)]) +
                rhs0[end]
    else
        d = last_row_𝐅𝐬⁻¹_analytical * 
            J[axes(last_row_𝐅𝐬⁻¹_analytical, 2), end-δn:end] .+ 
            J[end-δn:end, end-δn:end]
        rhs[end-δn:end] .= last_row_𝐅𝐬⁻¹_analytical *
            rhs0[axes(last_row_𝐅𝐬⁻¹_analytical, 2)] .+
            rhs0[end-δn:end]
    end
    Jcond[end-δn:end, end-δn:end] .= d

    # plot(heatmap(abs.(abs.(inv(P))) .> 1e-5; yflip = true, title = "invP"), 
        # heatmap(abs.(Jcond - Jcop) .> 1e-5; yflip = true, title = "δJ")) |> display

    # we build the linear system for the external variables in Jext and rhs_ext
    rhs_ext = build_external_system!(Jext, Jcond, rhs, In, Ntst, nbcoll, Npo, δn, N, m)

    if !USELU
        # gaussian elimination plus backward substitution to invert Jext
        _gaussian_elimination_external_pivoted!(Jext, rhs_ext, N, Ntst, δn)
        sol_ext = _backward_substitution_pivoted(Jext, rhs_ext, N, Ntst, δn)
    else
        F = lu(Jext)
        sol_ext = F \ rhs_ext
    end

    return _solve_for_internal_vars(coll, Jcond, rhs, sol_ext, δn)
end

@views function condensation_of_parameters!(cop_cache, coll::PeriodicOrbitOCollProblem, J, In, rhs0::Vector)
    N, m, Ntst = size(coll)
    n = N
    nbcoll = N * m
    Npo = length(coll) + 1
    nⱼ = size(J, 1)
    is_bordered = nⱼ == Npo
    δn =  nⱼ - Npo # this allows to compute the border side
    @assert δn >= 0

    𝒯 = eltype(coll)

    # cache to hold the factorized form of the matrix J
    Jcop = cop_cache.Jcoll
    # cache to hold the linear operator for the external variables
    Jext = cop_cache.Jext
    @assert size(Jext, 1) == size(Jext, 2) == Ntst*n+n+1+δn "Error with matrix of external variables. Please report this issue on the website of BifurcationKit. δn = $δn"

    Jcop[end, :] .= 0
    Jcop[:, end] .= 0
    Jcop[end, end] = J[end,end]

    # put periodic boundary condition
    Jcop[end-N-δn:end-1-δn, end-N-δn:end-1-δn] .= In
    Jcop[end-N-δn:end-1-δn, 1:N] .= (-1) .* In

    rg = 1:nbcoll
    rN = 1:N

    # the goal of the condensation of the parameters method is to remove the internal variables
    # by using gaussian elimination in each collocation block while removing the internal constraints
    # as well. 

    # recall that if F = lu(J) then
    # F.L * F.U = F.P * J
    # hence 𝐅𝐬⁻¹ = (P⁻¹ * L)⁻¹ = L⁻¹ * P
    # Now 𝐅𝐬 is with shape
    # ┌     ┐
    # │ A 0 │
    # │ c 1 │
    # └     ┘
    # This makes it easy to identify 𝐅𝐬⁻¹ which is also lower triangular by blocks. In particular c⁻¹ = c * A⁻¹, (computed with c' \ A)
    # Writing Jpo as
    # ┌       ┐
    # │ J  bⱼ │
    # │ cⱼ dⱼ │
    # └       ┘
    # we can identify 𝐅𝐬⁻¹⋅Jpo and the last row of this product, namely
    # c * A⁻¹ * J + cⱼ
    # last_row_𝐅𝐬⁻¹_analytical = zeros(𝒯, δn + 1, nⱼ) # last row of 𝐅𝐬⁻¹
    # last_row_𝐅𝐬 = zeros(𝒯, δn + 1, nⱼ) # last row of 𝐅𝐬

    @unpack blockⱼ,
            blockₙ,
            blockₙ₂,
            Lₜ,
            Uₜ,
            last_row_𝐅𝐬⁻¹_analytical,
            last_row_𝐅𝐬 = cop_cache
    
    rhs = zero(rhs0)
    p = zeros(Int, nbcoll + 1 + δn)
    pinv = zeros(Int, nbcoll + 1 + δn)

    d = zero(𝒯)
    for k in 1:Ntst
        blockⱼ[1:nbcoll, :] .= J[rg, rg .+ n]
        blockⱼ[nbcoll+1:(nbcoll + 1 + δn), :] .= J[Npo:(Npo+δn), rg .+ n]

        # the pivoting strategy is to ensure that the constraints 
        # get not mixed up with the collocation blocks
        F = lu!(blockⱼ, RowNonZero())
        @assert issuccess(F) "Failed LU factorization! Please report to the website of BifurcationKit."

        # get p .= F.p and pinv = invperm(p)
        _ipiv2perm!(p, F.ipiv, size(F, 1))
        _invperm!(pinv, p)

        @assert p[nbcoll+1] == nbcoll+1 "Pivoting strategy failed!!"
        if δn > 0
            @assert p[nbcoll+2] == nbcoll+2 "Pivoting strategy failed!!"
        end

        # Lₜ = LowerTriangular(F.L) # zero allocation?
        Lₜ.data .= F.factors[1:nbcoll, :]
        Uₜ.data .= Lₜ.data
        for i in axes(Lₜ, 1); Lₜ[i, i] = one(𝒯); end

        # we put the blocks in Jcop
        Jcop[rg, rg .+ N] .= Uₜ #UpperTriangular(F.factors[1:nbcoll, 1:nbcoll])

        # Jcop[rg, rN] .= P[rg, rg] \ J[rg, rN]
        # we have: P[rg, rg] = F.L[pinv[1:end-1-δn],:]
        # when δn = 0, we have blockₙ[1:nbcoll, 1:N] .= J[rg, rN][p_free,:]
        blockₙ[1:nbcoll, 1:N] .= J[rg[p[1:nbcoll]], rN]
        ldiv!(blockₙ₂, Lₜ, blockₙ)
        Jcop[rg, rN] .= blockₙ₂

        # last_row_𝐅𝐬[:, rg] .= F.L[pinv[end-δn:end], :] #!!! Allocates a lot !!!
        last_row_𝐅𝐬[end, rg] .= F.factors[pinv[end], :]
        if δn > 0
            last_row_𝐅𝐬[end-1, rg] .= F.factors[pinv[end-δn], :]
        end

        # condense RHS
        ldiv!(rhs[rg], Lₜ, rhs0[rg[p[1:nbcoll]]])

        # Jcop[end-δn:end, rg] .= -(last_row_𝐅𝐬[end-δn:end, rg] * Jcop[rg, rg]) .+ J[end-δn:end, rg]
        Jcop[end-δn:end, rg] .= J[end-δn:end, rg]
        mul!(Jcop[end-δn:end, rg], 
            last_row_𝐅𝐬[end-δn:end, rg], 
            Jcop[rg, rg], -1,1)

        # ldiv!(Jcop[rg, end-δn:end] , Lₜ, F.P[1:end-1-δn,1:end-1-δn] * J[rg, end-δn:end])
        ldiv!(Jcop[rg, end-δn:end], 
                Lₜ, 
                J[rg[p[1:end-1-δn]], end-δn:end])

        ###
        # last_row_𝐅𝐬⁻¹_analytical[:, rg] .= -F.L[pinv[end-δn:end], :] / ( F.P'*F.L)[1:end-1-δn, :]
        LinearAlgebra._rdiv!(last_row_𝐅𝐬⁻¹_analytical[:, rg], 
                                last_row_𝐅𝐬[:, rg], 
                                Lₜ)
        last_row_𝐅𝐬⁻¹_analytical[:, rg] .*= -1
        ###

        if k>=2
            # correction = P[Npo, rg .- nbcoll]' * Jcop[rg .- nbcoll, rN]
            mul!(Jcop[end-δn:end, rN], 
                last_row_𝐅𝐬[:, rg .- nbcoll], 
                Jcop[rg .- nbcoll, rN], -1, 1)
        end

        rg = rg .+ nbcoll
        rN = rN .+ nbcoll
    end
    rhs[end-N-δn:end-1, :] .= rhs0[end-N-δn:end-1, :]
    return rhs
end

@views function build_external_system!(Jext::Matrix{𝒯}, Jcond::Matrix{𝒯}, rhs::Vector{𝒯}, In, Ntst::Int, nbcoll::Int, Npo::Int, δn::Int, N::Int, m::Int) where {𝒯}
    Aᵢ = Matrix{𝒯}(undef, N, N)
    Bᵢ = Matrix{𝒯}(undef, N, N)

    r1 = 1:N
    r2 = N*(m-1)+1:(m*N)
    rN = 1:N

    # building the external variables
    fill!(Jext, 0)
    Jext[end-δn-N:end-δn-1,end-δn-N:end-δn-1] .= In
    Jext[end-δn-N:end-δn-1,1:N] .= (-1) .* In
    Jext[end-δn:end, end-δn:end] = Jcond[end-δn:end, end-δn:end]
    rhs_ext = zeros(𝒯, size(Jext, 1))

    # we solve for the external unknowns
    for _ in 1:Ntst
        Aᵢ .= Jcond[r2, r1]
        Bᵢ .= Jcond[r2, r1 .+ nbcoll]

        Jext[rN, rN] .= Aᵢ
        Jext[rN, rN .+ N] .= Bᵢ

        Jext[rN, end-δn:end] .= Jcond[r2, Npo:(Npo+δn)]

        Jext[end-δn:end, rN] .= Jcond[Npo:(Npo+δn), r1]
        Jext[end-δn:end, rN .+ N] .= Jcond[Npo:(Npo+δn), r1 .+ nbcoll]

        rhs_ext[rN] .= rhs[r2]

        r1 = r1 .+ nbcoll
        r2 = r2 .+ nbcoll
        rN = rN .+ N
    end
    rhs_ext[rN] .= rhs[r1]
    rhs_ext[end-δn:end] .= rhs[end-δn:end]
    # @error "" Jcond[end-3:end,end-2:end] Jext[end-2:end,end-3:end] maximum(abs, Jext[1:3,:]) maximum(abs, Jext)
    # heatmap((abs.(Jext)), yflip = true, title = "Jext") |> display
    return rhs_ext
end

@views function _solve_for_internal_vars(coll::PeriodicOrbitOCollProblem, Jcond, rhs::Vector{𝒯}, sol_ext, δn::Int) where {𝒯}
    N, m, Ntst = size(coll)
    nbcoll = N * m

    # solver for the internal unknowns
    ΔT = sol_ext[end-δn]
    Δp = sol_ext[end]

    r2 = N+1:(m)*N
    r1 = 1:(m-1)*N
    rsol = 1:(m-1)*N
    rN_left = 1:N
    rN = 1:N

    sol_cop = copy(rhs)
    rhs_tmp = zeros(𝒯, (m-1) * N)
    sol_tmp = copy(rhs_tmp)

    sol_cop[1:N] .= sol_ext[1:N]

    for iₜ in 1:Ntst
        Jtemp = UpperTriangular(Jcond[r1, r2])
        left_part = Jcond[r1, rN_left]
        right_part = Jcond[r1, r2[end]+1:r2[end]+N]

        # rhs_tmp = rhs[rsol] - left_part * sol_ext[rN] - right_part * sol_ext[rN .+ N] - ΔT * Jcond[r1, end]
        if δn == 0
            rhs_tmp .= @. rhs[rsol] -  ΔT * Jcond[r1, end] 
        elseif δn == 1
            rhs_tmp .= @. rhs[rsol] -  ΔT * Jcond[r1, end-1] - Δp * Jcond[r1, end] 
        else
            throw("")
        end
        mul!(rhs_tmp, left_part,  sol_ext[rN],      -1, 1)
        mul!(rhs_tmp, right_part, sol_ext[rN .+ N], -1, 1)

        ldiv!(sol_tmp, Jtemp, rhs_tmp)

        sol_cop[rsol .+ N] .= sol_tmp
        sol_cop[rsol[end]+N+1:rsol[end]+2N] .= sol_ext[rN .+ N]

        r1 = r1 .+ nbcoll
        r2 = r2 .+ nbcoll
        rN_left = rN_left .+ nbcoll
        rsol = rsol .+ nbcoll
        rN = rN .+ N
    end
    sol_cop[end-δn:end] .= sol_ext[end-δn:end]
    return sol_cop
end

function (ls::COPLS)(Jc, rhs)
    res = solve_cop(ls.cache.coll, Jc, rhs, ls.cache)
    return res, true, 1
end

# solve in dX, dl
# ┌                           ┐┌  ┐   ┌   ┐
# │ (shift⋅I + J)     dR      ││dX│ = │ R │
# │   ξu * dz.u'   ξp * dz.p  ││dl│   │ n │
# └                           ┘└  ┘   └   ┘
function (ls::COPBLS)(Jc, dR,
                    dzu, dzp::T, 
                    R::AbstractVecOrMat, n::T,
                    ξu::T = T(1), ξp::T = T(1);
                    shift::Ts = nothing, 
                    Mass::Tm = LinearAlgebra.I, 
                    applyξu! = nothing)  where {T <: Number, Ts, Tm}
    Jc = _get_matrix(Jc) # to handle FloquetWrapper
    if isnothing(shift)
        A = Jc
    else
        A = Jc + shift * Mass
    end
    rhs = vcat(R, n)
    # ls.J[1:end-1,1:end-1] .= A # this is quite slow, would be 8x faster to do ls.J .= A
    e(x, y) = for (xcol, ycol) ∈ zip(eachcol(x), eachcol(y))
        @views xcol[1:end - 1] .= ycol
        end
    e(ls.J, A)

    ls.J[1:end-1,end] .= dR
    ls.J[end,1:end-1] .= conj.(dzu .* ξu)
    ls.J[end,end] = dzp * ξp

    # apply a linear operator to ξu
    if isnothing(applyξu!) == false
        applyξu!(@view(ls.J[end, begin:end-1]))
    end
    res = solve_cop(ls.cache.coll, ls.J, rhs, ls.cache)
    return (@view res[begin:end-1]), res[end], true, 1
end


(lbs::COPBLS)(iter::AbstractContinuationIterable, 
                state::AbstractContinuationState,
                                    J, dR, 
                                    R, n::T; 
                                    shift::Ts = nothing, 
                                    Mass::Tm = LinearAlgebra.I) where {T, Ts, Tm} =
                                       (lbs)(J, dR,
                                           state.τ.u, state.τ.p,
                                           R, n,
                                           getθ(iter), one(T) - getθ(iter);
                                           shift,
                                           Mass,
                                           applyξu! = getdot(iter).apply!)

# ~/.julia/juliaup/julia-1.10.2+0.aarch64.apple.darwin14/share/julia/stdlib/v1.10/LinearAlgebra/src/lu.jl:134
@inbounds function _gaussian_elimination_external_pivoted!(J::AbstractMatrix{𝒯},
                                                rhs,
                                                n::Int,
                                                Ntst::Int,
                                                δn::Int ) where 𝒯
    st = 0
    nⱼ = size(J, 1)
    maxρ = zero(𝒯)
    iₚ = 0
    info = 0

    for nt = 1:Ntst-1
        for i = st+1:st+n
            # find the pivot

            iₚ = i
            Jmax = abs(J[i, i+n])
            for l = i:i+2n
                absl = abs(J[l, i+n])
                if absl > Jmax
                    iₚ = l
                    Jmax = absl
                end
            end

            if !iszero(J[iₚ, i+n])
                if iₚ != i
                    # rg = 1:nⱼ
                    rg = Iterators.flatten((1:n, st+1+n:st+3n, nⱼ-δn:nⱼ))
                    # swap rows
                    for j in rg
                        J[i,j], J[iₚ,j] = J[iₚ,j], J[i,j]
                    end
                    rhs[i], rhs[iₚ] = rhs[iₚ], rhs[i]
                end

                invpivot = inv(J[i,i+n])

                rg = i+1:nⱼ
                rg = Iterators.flatten((i+1:st+2n, nⱼ-δn:nⱼ))
                for l in rg
                    ρ = J[l,i+n] * invpivot
                    rhs[l] -= rhs[i] * ρ
                    # rg = 1:nⱼ
                    rgₖ = Iterators.flatten((1:n, st+1+n:st+3n, nⱼ-δn:nⱼ))
                    for jₖ in rgₖ
                        J[l, jₖ] -= J[i,jₖ] .* ρ
                    end
                end
            else
                info = i
            end
        end
        st += n
    end
    return J, rhs
end

@views function _backward_substitution_pivoted(Jext::Matrix{𝒯},
                                                rhs_ext,
                                                n::Int,
                                                Ntst::Int,
                                                δn::Int) where {𝒯}
    Jext_gauss = hcat(Jext[end-2n-δn:end,1:n], Jext[end-2n-δn:end,end-n-δn:end])
    rhs_ext_gauss = rhs_ext[end-2n-δn:end]
    sol_ext_gauss = Jext_gauss \ rhs_ext_gauss

    # backward substitution
    x₀ = sol_ext_gauss[1:n]
    xₘ = sol_ext_gauss[(1:n) .+ n]
    ΔT = sol_ext_gauss[end-δn]
    Δp = sol_ext_gauss[end]

    sol_ext = zero(rhs_ext)
    sol_ext[1:n] .= x₀
    sol_ext[end-δn-n:end] .= sol_ext_gauss[end-δn-n:end]

    rhs_tmp = zeros(𝒯, n)
    st = (Ntst-2)*n
    for iₜ in Ntst-1:-1:1
        if δn == 0
            rhs_tmp .= @. rhs_ext[(1:n) .+ st] - ΔT * Jext[(1:n) .+ st, end]
        else
            rhs_tmp .= @. rhs_ext[(1:n) .+ st] -
                            ΔT * Jext[(1:n) .+ st, end-1] -
                            Δp * Jext[(1:n) .+ st, end] 
        end
        mul!(rhs_tmp, Jext[(1:n) .+ st ,1:n], x₀, -1, 1)
        mul!(rhs_tmp, Jext[(1:n) .+ st, (1:n) .+ st .+ 2n], sol_ext[(1:n) .+ st .+ 2n], -1, 1)
        ldiv!(sol_ext[(1:n) .+ st .+ n], UpperTriangular(Jext[(1:n) .+ st, (1:n) .+ st .+ n]), rhs_tmp)
        st -= n
    end
    return sol_ext
end