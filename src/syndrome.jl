# Syndrome decoding

## outline
### 1. Compute the syndromes polynomial S(x) = ∑ᵢsᵢxⁱ
### 2. Compute the erasure/error locator polynomial Λ(x) = ∏ₖ(2^{iₖ}⋅xᵏ - 1) = ∑ᵢλᵢxⁱ
### 3. Compute the erasure/error evaluator polynomial Ω(x) = S(x)Λ(x) mod xⁿ
### 4. Compute the erasure/error magnitude polynomial eₖ = (2^{i_k}⋅Ω(2^{-i_k})) / (Λ'(2^{-i_k}))
### 5. Repair the input message simply by subtracting the magnitude polynomial from the input message

## Implementation
### 1. Berlekamp-Massey decoder
### 2. Euclidean decoder

module Syndrome

using QRCoders.Polynomial: mult, Poly, gfpow2, gflog2, gfinv, divide, unit,
                           iszeropoly, rstripzeros, degree, euclidean_divide
using QRDecoders: ReedSolomonError

###### --- division line --- ######

## common part
"""
    polynomial_eval(p::Poly, x::Int)

Evaluates the polynomial p(x) at x in GF256.
"""
function polynomial_eval(p::Poly, x::Int)
    val = last(p.coeff) ## leading term
    coeff = @view(p.coeff[end-1:-1:1])
    return foldl((i, j) -> mult(i, x) ⊻ j, coeff; init=val)
end

"""
    derivative_polynomial(p::Poly)

Computes the derivative of the polynomial p.
"""
function derivative_polynomial(p::Poly)
    lp = length(p)
    lp == 1 && return zero(Poly) ## constant polynomial
    coeff = Vector{Int}(undef, lp - 1)
    for (i, c) in enumerate(@view(p.coeff[2:end]))
        coeff[i] =  isodd(i) ? c : 0 ## i⋅x = 0 if i is even
    end
    return Poly(coeff)
end

"""
    reducebyHorner(p::Poly, a::Int)

Horner's rule, find the polynomial q(x) such that p(x)-(x-a)q(x) is a constant polynomial.
"""
function reducebyHorner(p::Poly, a::Int)
    reduced = Vector{Int}(undef, length(p))
    reduced[1] = val = last(p.coeff)
    coeff = @view(p.coeff[end-1:-1:1])
    for (i, c) in enumerate(coeff)
        val = mult(val, a) ⊻ c
        reduced[i + 1] = val
    end
    return Poly(reverse!(reduced))
end

"""
    findroots(p::Poly)

Computes the roots of the polynomial p using Horner's method.
Returns a empty list if p(x) contains duplicate roots or roots not in GF(256).
"""
function findroots(p::Poly)
    n = length(p) - 1
    roots = Vector{Int}(undef, n)
    for r in 0:255
        reducepoly = reducebyHorner(p, r)
        ## decrease the degree of the polynomial by 1
        popfirst!(reducepoly.coeff) == 0 || continue
        roots[n] = r
        n, p = n - 1, reducepoly
        n == 0 && return reverse!(roots)
    end
    ## p(x) contains duplicate roots or roots not in GF(256)
    return Int[] 
end

"""
    getpositions(Λx::Poly)

Caculate positions of errors from the error locator polynomial Λx.
Note that the indexs start from 0.
"""
getpositions(Λx::Poly) = mod.(-gflog2.(findroots(Λx)), 255)

"""
    syndrome_polynomial(received::Poly, nsym::Int)

Computes the syndrome polynomial S(x) for the received polynomial where `nsym` is the number of syndromes.
"""
function syndrome_polynomial(received::Poly, nsym::Int)
    ## S(x) = ∑ᵢsᵢxⁱ where sᵢ = R(2ⁱ) = E(2ⁱ)
    syndromes = polynomial_eval.(Ref(received), gfpow2.(0:(nsym-1)))
    return Poly(syndromes)
end

"""
    evaluator_polynomial(sydpoly::Poly, errlocpoly::Poly, nsym::Int)

Return the evaluator polynomial Ω(x) where Ω(x)≡S(x)Λ(x) mod xⁿ.
"""
evaluator_polynomial(sydpoly::Poly, errlocpoly::Poly, nsym::Int) = Poly((sydpoly * errlocpoly).coeff[1:nsym])

"""
    haserrors(received::Poly, nsym::Int)

Returns true if the received polynomial has errors. (may go undetected when the number of errors exceeds n)
"""
haserrors(received::Poly, nsym::Int) = !iszeropoly(syndrome_polynomial(received, nsym))

"""
    erratalocator_polynomial(errpos::AbstractVector)

Compute the erasures/error locator polynomial Λ(x) from the erasures/errors positions.
"""
function erratalocator_polynomial(errpos::AbstractVector)
    isempty(errpos) && return unit(Poly)
    return reduce(*, Poly([1, gfpow2(i)]) for i in errpos)
end

"""
    erratalocator_polynomial(sydpoly::Poly, nsym::Int; check=false)

Compute the error locator polynomial Λ(x)(without erasures).
The `check` tag ensures that Λx can be decomposed into products of one degree polynomials.
"""
erratalocator_polynomial(sydpoly::Poly, nsym::Int; check=false) = erratalocator_polynomial(sydpoly, Int[], nsym; check=check)

"""
    forney_algorithm(Λx::Poly, Ωx::Poly, errpos::AbstractVector)

Forney algorithm, returns the error-corrected values.
eₖ = 2^{iₖ}⋅Ω(2^{-iₖ}) / Λ'(2^{-iₖ})
"""
function forney_algorithm(Λx::Poly, Ωx::Poly, errpos::AbstractVector)
    ## derivative of the error locator polynomial
    errderi = derivative_polynomial(Λx)
    forneynum(k) = mult(gfpow2(k), polynomial_eval(Ωx, gfpow2(-k))) ## numerator
    forneyden(k) = polynomial_eval(errderi, gfpow2(-k)) ## denominator
    return @. divide(forneynum(errpos), forneyden(errpos))
end

"""
    fillerasures(received::Poly, errpos::AbstractVector, nsym::Int)

Forney algorithm, computes the values (error magnitude) to correct the input message.

Warnning: The output polynomial might be incorrect if `errpos` is incomplete.
"""
fillerasures(received::Poly, errpos::AbstractVector, nsym::Int) = fillerasures!(copy(received), errpos, nsym)
function fillerasures!(received::Poly, errpos::AbstractVector, nsym::Int)
    ## number of errors exceeds limitation of the RS-code
    length(errpos) > nsym && throw(ReedSolomonError())

    ## syndrome polynomial S(x)
    sydpoly = syndrome_polynomial(received, nsym) 
    
    ## error locator polynomial
    Λx = erratalocator_polynomial(errpos)
    
    ## evaluator polynomial Ω(x)≡S(x)Λ(x) mod xⁿ
    Ωx = evaluator_polynomial(sydpoly, Λx, nsym)
    
    ## computes error magnitudes using Forney algorithm 
    received.coeff[1 .+ errpos] .⊻= forney_algorithm(Λx, Ωx, errpos)
    return received
end

###### --- division line --- ######

## Berlekamp-Massey decoder

"""
    modified_syndrome(syndpoly::Poly, erasures::AbstractVector)

Computes the modified syndrome polynomial.
"""
# modified_syndrome(sydpoly::Poly, erasures::AbstractVector) = modified_syndrome!(copy(sydpoly), erasures)
# function modified_syndrome!(sydpoly::Poly, erasures::AbstractVector)
#     n = length(sydpoly)
#     S = sydpoly.coeff
#     for i in erasures, j in 1:(n - 1)
#         S[j] = mult(gfpow2(i), S[j]) ⊻ S[j+1]
#     end
#     sydpoly
# end

"""
    erratalocator_polynomial(sydpoly::Poly, erasures::AbstractVector, n::Int)

Berlekamp-Massey algorithm, compute the error locator polynomial Λ(x)(given the erased positions).
The `check` tag ensures that Λx can be decomposed into products of one degree polynomials.
"""
function erratalocator_polynomial(sydpoly::Poly, erasures::AbstractVector, nsym::Int; check=false)
    ## syndromes
    S = sydpoly.coeff
    ## initialize via erased data
    L = ρ = length(erasures) ## number of erased data
    Λx = erratalocator_polynomial(erasures) ## erased locator polynomial
    Bx = copy(Λx)
    x = Poly([0, 1])

    ## discrepancy Δᵣ = Λ₀Sᵣ₋₁ + Λ₁Sᵣ₋₂ + ⋯ 
    getdelta(r) = @views reduce(⊻, mult(i, j) for (i, j) in zip(S[r:-1:1], Λx.coeff))
    
    ## iteration
    for r in (ρ + 1):nsym
        Δ = getdelta(r)
        if Δ == 0 || 2 * L > r + ρ - 1 # condition updates
            Λx, Bx = Λx + Δ * x * Bx, x * Bx
        else # δ = 1
            L = r - L - ρ
            Λx, Bx = Λx + Δ * x * Bx, gfinv(Δ) * Λx
        end
    end
    Λx = rstripzeros(Λx)
    
    ## number of errors exceeds limitation of the RS-code
    v = length(Λx) - 1 - ρ # number of errors
    if iszeropoly(Λx) || 2 * v + ρ > nsym
        throw(ReedSolomonError())
    end
    
    ## check if the error locator polynomial is a product of one degree polynomials
    check && isempty(getpositions(Λx)) && throw(ReedSolomonError())
    return Λx
end

"""
    BMdecoder(received::Poly, erasures::AbstractVector, nsym::Int)

Berlekamp-Massey algorithm, decode message polynomial from received polynomial(given erasures).
"""
BMdecoder(received::Poly, erasures::AbstractVector, nsym::Int) = BMdecoder!(copy(received), erasures, nsym)

function BMdecoder!(received::Poly, erasures::AbstractVector, nsym::Int)
    ## check data
    length(received) > 255 && throw(DomainError(received, "length of received polynomial must be less than 256"))
    length(erasures) > nsym && throw(ReedSolomonError())

    ## syndrome polynomial S(x)
    sydpoly = syndrome_polynomial(received, nsym)
    iszeropoly(sydpoly) && return received ## no errors

    ## error locator polynomial
    Λx = erratalocator_polynomial(sydpoly, erasures, nsym)

    ## error positions
    errpos = getpositions(Λx)
    isempty(errpos) && throw(ReedSolomonError())

    ## evaluator polynomial Ω(x)≡S(x)Λ(x) mod xⁿ
    Ωx = evaluator_polynomial(sydpoly, Λx, nsym)
    
    ## computes error magnitudes using Forney algorithm
    received.coeff[1 .+ errpos] .⊻= forney_algorithm(Λx, Ωx, errpos)
    return received
end

"""
    BMdecoder(received::Poly, nsym::Int)

Berlekamp-Massey algorithm, decode message polynomial from received polynomial(without erasures).
"""
BMdecoder(received::Poly, nsym::Int) = BMdecoder!(copy(received), Int[], nsym)

### --- division line --- ###

## Euclidean Decoder

"""
    extended_euclidean_divide(r₁::Poly, r₂::Poly)

Return polynomials u(x) and v(x) such that u(x)r₁(x) + v(x)r₂(x) = gcd(r₁(x), r₂(x)).

## illustration
Let rₖ = uₖr₁ + vₖr₂, k ≥ 2\\
    r₀ = q₀⋅r₁ + r₂ => r₂ = r₀ - q₀r₁, where r₀=r₂, q₀=0\\
    r₁ = q₁⋅r₂ + r₃ => r₃ = r₁ - q₁⋅r₂\\
    r₂ = q₂⋅r₃ + r₄ => r₄ = r₂ - q₂⋅r₃\\
    rₖ = qₖ⋅r_{k+1} + r_{k+2} => r_{k+2} = rₖ - qₖ⋅r_{k+1}\\
                              => r_{k+2} = uₖr₁ + vₖr₂ - qₖ(u_{k+1}r₁ + v_{k+1}r₂)\\
                                         = (uₖ - qₖ(u_{k+1})r₁ + (vₖ - qₖv_{k+1})r₂\\
                              => u_{k+1} = uₖ - qₖu_{k+1}\\
                                 v_{k+1} = vₖ - qₖv_{k+1}\\
    u₂, v₂ = 0, 1\\
    u₃, v₃ = 1, -q₁\\
    loop until\\
    rₜ = qₜ⋅r_{t+1} + 0 => r_{t+1} is the great common factor of r₁ and r₂
"""
function extended_euclidean_divide(r₁::Poly, r₂::Poly)
    u₁, v₁, u₂, v₂ = Poly.([[1], [0], [0], [1]])
    iszeropoly(r₂) && return u₁, v₁, r₁
    q, r₃ = euclidean_divide(r₁, r₂)
    # case r₁ == 0 => r₁ = 0⋅r₂ + 0 
    #              => r₃ == 0 => covered by the following loop
    while !iszeropoly(r₃) ## if rₖ == 0, then r_{k-1} = gcd(r₁, r₂)
        # @assert r₁ = u₁raw₁ + v₁raw₂
        # @assert r₂ = u₂raw₁ + v₂raw₂
        u₁, v₁, u₂, v₂ = u₂, v₂, u₁ + q * u₂, v₁ + q * v₂
        # @assert r₂ = u₁raw₁ + v₁raw₂
        # @assert r₃ = u₂raw₁ + v₂raw₂
        r₁, r₂ = r₂, r₃
        q, r₃ = euclidean_divide(r₁, r₂)
    end
    return u₂, v₂, r₂
end

"""
    Sugiyama_euclidean_divide(r₁::Poly, r₂::Poly, upperdeg::Int)

Yasuo Sugiyama's adaptation of the Extended Euclidean algorithm.
Find u(x), v(x) and r(x) s.t. r(x) = u(x)r₁(x) + v(x)r₂(x) where r(x) = gcd(r₁(x), r₂(x)) or deg(r(x)) ≤ upperdeg.
"""
function Sugiyama_euclidean_divide(r₁::Poly, r₂::Poly, upperdeg::Int)
    u₁, v₁, u₂, v₂ = Poly.([[1], [0], [0], [1]])
    iszeropoly(r₂) && return u₁, v₁, r₁
    q, r₃ = euclidean_divide(r₁, r₂)
    while degree(r₂) > upperdeg && !iszeropoly(r₃)
        # @assert r₁ = u₁raw₁ + v₁raw₂
        # @assert r₂ = u₂raw₁ + v₂raw₂
        u₁, v₁, u₂, v₂ = u₂, v₂, u₁ + q * u₂, v₁ + q * v₂
        # @assert r₂ = u₁raw₁ + v₁raw₂
        # @assert r₃ = u₂raw₁ + v₂raw₂
        r₁, r₂ = r₂, r₃
        q, r₃ = euclidean_divide(r₁, r₂)
    end
    return rstripzeros.((u₂, v₂, r₂))
end

"""
    euclidean_decoder(received::Poly, erasures::AbstractVector, nsym::Int)

Decode the received polynomial using the Euclidean algorithm(with erasures).
"""
euclidean_decoder(received::Poly, erasures::AbstractVector, nsym::Int) = euclidean_decoder!(copy(received), erasures, nsym)
function euclidean_decoder!(received::Poly, erasures::AbstractVector, nsym::Int)
    ## check data
    length(received) > 255 && throw(DomainError(received, "length of received polynomial must be less than 256"))
    length(erasures) > nsym && throw(ReedSolomonError())

    ## syndrome polynomial
    sydpoly = syndrome_polynomial(received, nsym)
    iszeropoly(sydpoly) && return received
    
    ## erasures locator polynomial Γx
    Γx = erratalocator_polynomial(erasures)
    xn = Poly(push!(zeros(Int, nsym), 1))
    
    ## deg(Ω(x))  ≤ ⌊(nsym + length(erasures)) / 2⌋ - 1
    upperdeg = (nsym + length(erasures)) ÷ 2 - 1
    ## error locator polynomial Λx
    ## evaluator polynomial evlpoly
    Λx, _, Ωx = Sugiyama_euclidean_divide(sydpoly * Γx, xn, upperdeg)
    
    ## errata locator polynomial
    errataloc = Λx * Γx
    
    ## errors positions + erasures positions
    errpos = vcat(getpositions(Λx), erasures)
    length(errpos) != length(errataloc) - 1 && throw(ReedSolomonError)
    
    ## Forney algorithm
    received.coeff[1 .+ errpos] .⊻= forney_algorithm(errataloc, Ωx, errpos)
    return received    
end

"""
    euclidean_decoder(received::Poly, erasures::AbstractVector, nsym::Int)

Decode the received polynomial using the Euclidean algorithm(without erasures).
"""
euclidean_decoder(received::Poly, nsym::Int) = euclidean_decoder!(copy(received), Int[], nsym)


end