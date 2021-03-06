# Define variables used throughout the package and functions to initialize them.

export SALTParam
export gain, gain′, hole_burning!, create_A!

# Below, allow vectors and matrices to be PETSc ones if their sizes are 3×(# of grid points).
# If their sizes are the number of modes, keep them Julia vectors.

# About avoiding overtyping container-type variables:
#
# Below, for read-only container-type variables, I specify neither the container type nor
# eltype concretely.  [What are the examples of read-only container-type variables?]
#
# However, for variables into which I write, I don't specify the container type concretely
# (so that I can allow various container type, such as Julia vectors and PETSc vectors), but
# I do specify the eltype, because otherwise I get InexactError, which complains about
# incompatible element type (e.g., when attempting to store Complex128 in Float64).  [I'm
# not sure what I intended to mean here.]
#
# For this reason, I have two aliases for abstract container types: one with a concrete
# eltype and the other with an abstract eltype.  For example, I have AbsVecComplex with a
# concrete eltype of Complex128, and also AbsVecNumber with an abstract eltype of Number.
#
# Consider SATLParam below.  εc is typed differently when it is used as a field and as an
# argument of a constructor.
# - The field type VC of εc, into which I write, is a subtype of AbsVecComplex, whose eltype
# is the concrete Complex128.
# - On the other hand, the argument type of εc in the inner constructor is not AbsVecComplex,
# but AbsVecNumber, because even if its element is not typed Complex128, it is converted to
# a vector with Complex128 when writing in the field εc of SALTParam.  (Note that the
# argument εc of the inner constructor is copied to the field εc, so it is read-only.)
# - [I think this item is outdated, because the current outer constructor take εc of
# AbsVecNumber type.]  Still, in the outer constructor, the argument type of εc is not
# AbsVecNumber but AbsVecComplex.  This is because we want to call the inner constructor
# while specifying the type of εc concretely for type stability, and the eltype of the field
# εc is not necessarily the same as the eltype of the argument εc.  Specifically, if we type
# εc as AbsVecNumber at the signature of the outer constructor, then we can pass a PETSc
# vector of Float64 to it, and I would want to use a PETSc vector of Complex128 for VC.  How
# would I be able to deduce such a type?  Upon calling the outer constructor, the concrete
# type of the argument εc, i.e., PETSc vector of Float64, is decided, but still I cannot
# deduce Complex128 from Float64...  [Well, technically this is doable even if the eltype of
# the argument εc was Int64, by complex(float(eltype(εc))).  Wait, maybe PETSc's Float64 is
# not Julia's Float64, so PETSc.jl must overload float() and complex() functions for this
# capability?  In that case, even if such deduction was possible in PETSc.jl, similar
# deduction might not be possible for other vector types, so it's safe to use a concrete
# eltype in the outer constructor?]
#
# The same principle applies to writing functions as well as types.  If the function changes
# the contents of some variable, that variable is where I write, so its eltype must be
# specified to avoid InexactError.  For example, in create_A!, the argument A is where the
# output is stored, so it had better have Complex128 as the eltype, so I type it as
# AbsMatComplex.  On the other hand, the argument CC is read-only, so it is typed AbsMatNumber.

# Parameters defining the SALT problem
# Consider including CC to param, if I am really going to use ωₐ for PML for all modes.
mutable struct SALTParam{VC<:AbsVecComplex,VF<:AbsVecFloat}  # VC, VF can be PETSc vectors
    ωₐ::Float  # atomic transition angular frequency
    γ⟂::Float  # relaxation rate of polarization
    εc::VC  # permittivity of cold cavity
    D₀::VF  # pump strength
    function SALTParam{VC,VF}(ωₐ::Real,
                              γ⟂::Real,
                              εc::AbsVecNumber,
                              D₀::AbsVecReal) where {VC<:AbsVecComplex,VF<:AbsVecFloat}
        length(εc) == length(D₀) ||
            throw(ArgumentError("legnth(εc) == $(length(εc)) and length(D₀) == $(length(D₀)) must be the same"))

        return new(ωₐ, γ⟂, εc, D₀)
    end
end

# # The following constructor avoids copying εc and D₀.
# SALTParam(ωₐ::Real, γ⟂::Real, εc::VC, D₀::VF) where {VC<:AbsVecComplex,VF<:AbsVecFloat} =
#     SALTParam{VC,VF}(ωₐ, γ⟂, εc, D₀)

# The following constructor copies εc and D₀.
function SALTParam(ωₐ::Real, γ⟂::Real, εc::AbsVecNumber, D₀::AbsVecReal)
    εc_new = similar(εc,CFloat)
    copy!(εc_new, εc)

    D₀_new = similar(D₀,Float)
    copy!(D₀_new, D₀)

    return SALTParam{typeof(εc_new), typeof(D₀_new)}(ωₐ, γ⟂, εc_new, D₀_new)
end

# To do: check if the following works for vtemp of PETSc vector type.
SALTParam(vtemp::AbsVec) =  # template vector with N entries
    SALTParam(0, 0, similar(vtemp,CFloat).=0, similar(vtemp,Float).=0)
SALTParam(N::Integer) = SALTParam(Vector{Float}(N))


gain(ω::Number, ωₐ::Number, γ⟂::Number) = γ⟂ / (ω - ωₐ + im * γ⟂)  # scalar
gain′(ω::Number, ωₐ::Number, γ⟂::Number) = -γ⟂ / (ω - ωₐ + im * γ⟂)^2  # scalar


# Evaluate the hole-burning term + 1 = 1 + ∑a²|ψ|².
function hole_burning!(hb::AbsVecFloat,  # output
                       a²::AbsVecReal,  # vector of squared amplitudes of unnormalized eigenmodes
                       ψ::AbsVec{<:AbsVecNumber})  # vector of normalized eigenmodes
    hb .= 1  # initialize
    for m = 1:length(a²)
        if a²[m] ≠ 0
            # info("a²[$m] = $(a²[m]), ‖ψ[$m]‖ = $(norm(ψ[m]))")
            hb .+=  a²[m] .* abs2.(ψ[m])
        end
    end
    # info("‖hb‖ = $(norm(hb))")

    return nothing
end


# Create ∇×∇× - ω² (ε + γ(ω) D).
function create_A!(A::AbsMatComplex,  # output; must have same nonzero entry pattern as CC
                   CC::AbsMatNumber,  # curl of curl (∇×∇×)
                   ω::Number,  # angular frequency
                   ε::AbsVecNumber)  # effective ε
    A .= CC  # initialize; works for sparse matrices with same nonzero entry pattern
    # info("‖CC‖₁ = $(norm(CC,1)), ω = $ω, ‖ε‖ = $(norm(ε))")
    for i = 1:length(ε)
        A[i,i] -= ω^2 * ε[i]
    end

    return nothing
end
