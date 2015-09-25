"""
## AbstractRaggedArray

The AbstractRaggedArray is a subtype of AbstractArray with four parameters:
* T: The element type
* N: The dimensionality
* RD: The ragged dimension
* OD: The number of dimensions after the ragged dimension (N-RD)

In addition to implementing the AbstractArray methods, AbstractRaggedArray
subtypes should implement `raggedlengths`. `Base.size` should return the maximum
extents of the array. They *must not* implement the Base `unsafe_get/setindex`
methods.
"""
abstract AbstractRaggedArray{T,N,RD,OD} <: AbstractArray{T,N}

"""
## RaggedDimension

The RaggedDimension is a simple wrapper type that allows the list of ragged
slice lengths to behave as the maximum size in a limited number of cases. In
this fashion, it's able to behave as the maximum rectangular extent in some
Base AbstractArray methods.
"""
immutable RaggedDimension{T<:Union{Tuple,AbstractArray}}
    szs::T # An iterable container of lengths for each ragged slice
end
# This is a little sketchy, but a RaggedDimension(::Real) is not ragged
RaggedDimension(i::Real) = convert(Int, i)

import Base: ==
=={T}(a::RaggedDimension{T}, b::RaggedDimension{T}) = a.szs == b.szs
=={T<:Union{Tuple,AbstractArray}}(a::RaggedDimension{T}, b::T) = a.szs == b
=={T<:Union{Tuple,AbstractArray}}(b::RaggedDimension{T}, a::T) = b.szs == a
==(a::RaggedDimension, b::RaggedDimension) = (for (x,y) in zip(a, b); x == y || return false; end; return true)
==(a::Union{Tuple,AbstractArray}, b::RaggedDimension) = (for (x,y) in zip(a, b); x == y || return false; end; return true)
==(a::RaggedDimension, b::Union{Tuple,AbstractArray}) = (for (x,y) in zip(a, b); x == y || return false; end; return true)
# TODO: Hash tuples and all abstract arrays the same: by their contents
Base.hash(a::RaggedDimension, h::UInt) = hash(a.szs, hash(UInt(0xe4daeb7692ca0a52), h))


Base.start(d::RaggedDimension) = start(d.szs)
Base.next(d::RaggedDimension, s) = next(d.szs, s)
Base.done(d::RaggedDimension, s) = done(d.szs, s)
Base.getindex(d::RaggedDimension, idxs...) = RaggedDimension(getindex(d.szs, idxs...))

Base.maximum(a::RaggedDimension) = maximum(a.szs)

Base.colon(start::Real, stop::RaggedDimension) = colon(start, maximum(stop))
Base.colon(start::Real, step::Real, stop::RaggedDimension) = colon(start, step, maximum(stop))
Base.colon(start::RaggedDimension, stop::Real) = colon(maximum(start), stop)
Base.colon(start::RaggedDimension, step::Real, stop::Real) = colon(maximum(start), step, stop)

Base.isless(a::RaggedDimension, b::RaggedDimension) = isless(maximum(a), maximum(b))
Base.isless(a::Int, b::RaggedDimension) = isless(a, maximum(b))
Base.isless(a::RaggedDimension, b::Int) = isless(maximum(a), b)

#TODO: I really don't like this... but it's needed for SubArrays
import Base: *
*(i::Int, d::RaggedDimension) = i*maximum(d)

# TODO: I also don't like this... but it's a stand-in until I get
# multi-arg RaggedSlow eachindex up and running
Base.call{N}(::Type{CartesianIndex{N}}, index::Union{Integer,RaggedDimension}...) = CartesianIndex{N}(index)
Base.call{N}(::Type{CartesianIndex{N}}, index::NTuple{N,Union{Integer,RaggedDimension}}) = CartesianIndex{N}(map(maximum, index))

"""
    raggedlengths(R, indexes...)

As a special extension to size, all `AbstractRaggedArray`s allow looking up
the ragged lengths along the ragged dimension by providing context in the form
of the trailing `indexes` for the outer dimensions. The indexes need not index
at the full dimensionality of the array. The indexes may be non-scalar, in
which case a RaggedDimension containing the lengths of each slice is returned.
"""
@inline raggedlengths{T,N,RD}(R::AbstractRaggedArray{T,N,RD}, idxs...) = _raggedlengths(R, size(R, RD), idxs...)
@generated function _raggedlengths{T<:AbstractArray,_,N,RD}(R::AbstractRaggedArray{_,N,RD}, d::RaggedDimension{T}, idxs...)
    # Use plain-old indexing to look up the ragged lengths
    outer_sz = Expr(:tuple, [:(size(R, $d)) for d=RD+1:N]...)
    quote
        sz = $outer_sz
        if size(d.szs) == sz
            return d[idxs...]
        else
            return RaggedDimension(reshape(d.szs, sz)[idxs...])
        end
    end
end
@generated function _raggedlengths{T<:AbstractArray,_,N,RD}(R::AbstractRaggedArray{_,N,RD}, d::RaggedDimension{T}, idxs...)
    # Use plain-old indexing to look up the ragged lengths
    outer_sz = Expr(:tuple, [:(size(R, $d)) for d=RD+1:N]...)
    length(idxs) == 1 && return :(d[idxs[1]])
    quote
        sz = $outer_sz
        if size(d.szs) == sz
            return d[idxs...]
        else
            return RaggedDimension(reshape(d.szs, sz)[idxs...])
        end
    end
end




@generated function rectsize{T,N,RD}(R::AbstractRaggedArray{T,N,RD})
    Expr(:tuple, [:(size(R, $d)) for d=1:RD-1]..., :(maximum(size(R, $RD))), [:(size(R, $d)) for d=RD+1:N]...)
end
# This is rather inefficient - subtypes should specialize this if their ragged
# structure supports a different way of computing the total number of elements.
@generated function Base.length{T,N,RD}(R::AbstractRaggedArray{T,N,RD})
    inner_sz = Expr(:tuple, [:(size(R, $d)) for d=1:RD-1]...)
    outer_sz = Expr(:tuple, [:(size(R, $d)) for d=RD+1:N]...)
    quote
        rag_sz = 0
        for i=1:prod($outer_sz)
            rag_sz += raggedlengths(R, i)
        end
        return rag_sz * prod($inner_sz)
    end
end

# similar without changing dimensions -- use the same ragged sizes, too!
Base.similar{T}(R::AbstractRaggedArray{T}) = similar(R, T)
Base.similar{T,N,RD,OD,S}(R::AbstractRaggedArray{T,N,RD,OD}, ::Type{S}) = similar(R, S, raggedsize(R))
# similar with a different ragged size
Base.similar(R::AbstractRaggedArray, I::Union{Int,RaggedDimension}...) = similar(R, I)
Base.similar{T}(R::AbstractRaggedArray{T}, I::Tuple{Vararg{Union{Int,RaggedDimension}}}) = similar(R, T, I)
Base.similar{T}(R::AbstractRaggedArray, ::Type{T}, I::Union{Int,RaggedDimension}...) = similar(R, T, I)
# similar with a non-ragged size becomes a regular Array
Base.similar{T}(R::AbstractRaggedArray, ::Type{T}, I::Tuple{Vararg{Int}}) = Array(T, I...)


import Base: trailingsize, throw_boundserror

# Check both the ragged and rectangular bounds for an AbstractRaggedArray
@generated function Base.checkbounds{_,AN,RD}(A::AbstractRaggedArray{_,AN,RD}, I...)
    meta = Expr(:meta, :inline)
    N = length(I)
    N <= RD && return :(throw(ArgumentError("linear indexing through a ragged dimension is unsupported")))
    Isplat = [:(I[$d]) for d=1:N]
    error = :(throw_boundserror(A, tuple($(Isplat...))))
    outer_idxs = Expr[:(I[$d]) for d=RD+1:N]
    args = Expr[]
    for dim=1:N-1
        dim == RD && continue # Check the ragged dimension last
        push!(args, :(checkbounds(Bool, size(A,$dim), I[$dim]) || $error))
    end
    push!(args, :(checkbounds(Bool, trailingsize(A,Val{$N}), I[$N]) || $error))
    # Check the ragged dimension
    if all(i->i<:Real, I[RD+1:N])
        # With all-scalar outer indexes, just use them as a ragged length lookup
        push!(args, :(checkbounds(Bool, raggedlengths(A, $(outer_idxs...)), I[$RD]) || $error))
    else
        # Otherwise, there may be different ragged lengths across the indexes
        push!(args, quote
            raglens = raggedlengths(A, $(outer_idxs...)) # An array of lengths
            for r in raglens
                checkbounds(Bool, r, I[$RD]) || $error
            end
        end)
    end
    Expr(:block, meta, args...)
end
