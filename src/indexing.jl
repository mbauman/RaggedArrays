# Nonscalar indexing is so close to being able to punt to the base library...
# were it not for colons along the ragged dimension.
# This is adapted from JuliaLang/julia#12567
to_index(I::AbstractArray{Bool}) = find(I)
to_index(I::AbstractArray) = I
to_index(i) = i
# shape of array to create for getindex() with indexes I, dropping trailing scalars
index_shape(A::AbstractRaggedArray, I::AbstractArray) = error("linear indexing not supported")
index_shape(A::AbstractRaggedArray, I::AbstractArray{Bool}) = error("linear indexing not supported")
index_shape(A::AbstractRaggedArray, I::Colon) = error("linear indexing not supported")
@generated function index_shape{_,__,RD}(A::AbstractRaggedArray{_,__,RD}, I...)
    N = length(I)
    sz = Expr(:tuple)
    outer_idxs = [:(I[$d]) for d=RD+1:N]
    for d=1:N
        if !any(i->i<:Union{AbstractArray,Colon}, I[d:end])
            break
        elseif I[d] <: Colon
            if d == RD
                # If there's a Colon over the ragged dimension, return the
                # selected ragged size(s). If the outer indices aren't all
                # scalars, this will return an array and force the creation
                # of a new AbstractRaggedArray for the indexed output.
                push!(sz.args, :(RaggedDimension(raggedlengths(A, $(outer_idxs...)))))
            else
                push!(sz.args, d < N ? :(size(A, $d)) : :(trailingsize(A, Val{$d})))
            end
        elseif I[d] <: AbstractArray{Bool}
            push!(sz.args, :(sum(I[$d])))
        elseif I[d] <: AbstractVector
            push!(sz.args, :(length(I[$d])))
        else
            push!(sz.args, 1)
        end
    end
    quote
        $(Expr(:meta, :inline))
        $sz
    end
end

abstract RaggedIndexing <: Base.LinearIndexing
immutable RaggedFast <: RaggedIndexing; end
immutable RaggedSlow <: RaggedIndexing; end

# For fast linear indexing, we create a custom integer type that can act as a
# flag for callers who opt-in to ragged behaviors. Linear indexing with regular
# Ints is ambiguous.
immutable LinearIndex <: Integer
    data::Int
end
import Base: <, <=, +, -
<(a::LinearIndex, b::LinearIndex) = a.data < b.data
<=(a::LinearIndex, b::LinearIndex) = a.data <= b.data
+(a::LinearIndex, b::LinearIndex) = LinearIndex(a.data + b.data)
-(a::LinearIndex) = LinearIndex(-a.data)
-(a::LinearIndex, b::LinearIndex) = LinearIndex(a.data - b.data)
Base.convert(::Type{Int}, a::LinearIndex) = a.data
Base.convert(::Type{LinearIndex}, x::Int) = LinearIndex(x)
Base.promote_rule(::Type{LinearIndex}, ::Type{Int}) = LinearIndex

Base.eachindex(::RaggedFast, R::AbstractArray) = LinearIndex(1):LinearIndex(length(R))
function Base.eachindex(::RaggedFast, R::AbstractArray, Rs::AbstractArray...)
    # ensure all sizes are equal; see JuliaLan/julia#13310
    sz = size(R)
    for r in Rs
        sz == size(r) || throw(DimensionMismatch())
    end
    LinearIndex(1):LinearIndex(length(R))
end

using Base.Cartesian
import Base: cartindex_exprs, checksize, unsafe_getindex
indexref(idx, i::Int) = idx
indexref(::Colon, i::Int) = i
@inline indexref(A::AbstractArray, i::Int) = unsafe_getindex(A, i)
convert_ints() = ()
@inline convert_ints(x, xs...) = (convert(Int, x), convert_ints(xs...)...)

# Just use one big generated method to do all the fallback dispatch in one place.
@generated function Base.getindex{T,AN,RD}(A::AbstractRaggedArray{T,AN,RD}, I...)
    meta = Expr(:meta, :inline)
    N = length(I)
    Isplat = [:(I[$d]) for d=1:N]
    # Expand any cartesian indices first
    any(i->i<:CartesianIndex, I) && return :($meta; getindex(A, $(cartindex_exprs(I, :I)...)))
    # If we're explicitly using linear indexing, use ragged_ind2sub
    length(I) == 1 && I[1] <: LinearIndex && return :($meta; getindex(A, ragged_ind2sub(A, I)...))
    # Then ensure we're not linear indexing
    N <= RD && return :(throw(ArgumentError("linear indexing through a ragged dimension is unsupported")))
    # If all indices are Int, then the AbstractRaggedArray subtype didn't define indexing
    all(i->i<:Int, I) && return :(error("indexing not defined for $(typeof(A))"))
    # Convert scalar indexing with numbers to integers so subtypes just define ::Int
    all(i->i<:Number, I) && return :($meta; getindex(A, convert_ints(I...)...))
    !any(i->i<:Union{AbstractArray,Colon}, I) && return :(throw(ArgumentError("unsupported indexes $I")))
    # Finally, do multi-dimensional indexing, based on linear slow getindex
    quote
        checkbounds(A, $(Isplat...))
        @nexprs $N d->(I_d = to_index(I[d]))
        dest = similar(A, @ncall $N index_shape A I)
        @ncall $N checksize dest I # TODO: stricter checksize for ragged arrays?
        @ncall $N getindex! dest A I
    end
end

# We define our own unsafe operators, since Base methods assume that the
# unsafe_* methods are always "safe" within 1:size(A, d).
@inline ragged_unsafe_getindex(R::AbstractRaggedArray, I...) = getindex(R, I...)
@inline ragged_unsafe_setindex!(R::AbstractRaggedArray, v, I...) = setindex!(R, v, I...)

# Assigning output to a non-ragged array
@generated function getindex!(dest::AbstractArray, src::AbstractRaggedArray, I...)
    N = length(I)
    quote
        D = eachindex(dest)
        Ds = start(D)
        @nloops $N i dest d->(j_d = indexref(I[d], i_d)) begin
            d, Ds = next(D, Ds)
            v = @ncall $N ragged_unsafe_getindex src j
            Base.unsafe_setindex!(dest, v, d)
        end
        dest
    end
end

# Adapted from Base.Cartesian's @nloops: ragged iteration!
macro ragged_nloops(N, itersym, rangeexpr, args...)
    _ragged_nloops(N, itersym, rangeexpr, args...)
end
import Base.Cartesian: inlineanonymous
function _ragged_nloops(N::Int, RD::Int, itersym::Symbol, arraysym::Symbol, args::Expr...)
    if !(1 <= length(args) <= 3)
        throw(ArgumentError("number of arguments must be 1 ≤ length(args) ≤ 3, got $nargs"))
    end
    body = args[end]
    ex = Expr(:escape, body)
    for dim = 1:N
        itervar = inlineanonymous(itersym, dim)
        rng = dim == RD ? :(1:raggedlengths($arraysym, $([symbol(itersym, :_, d) for d=RD+1:N]...))) :
                          :(1:size($arraysym, $dim))
        preexpr = length(args) > 1 ? inlineanonymous(args[1], dim) : (:(nothing))
        postexpr = length(args) > 2 ? inlineanonymous(args[2], dim) : (:(nothing))
        ex = quote
            for $(esc(itervar)) = $(esc(rng))
                $(esc(preexpr))
                $ex
                $(esc(postexpr))
            end
        end
    end
    ex
end

# Assigning output to a ragged array
@generated function getindex!{_,__,RD}(dest::AbstractRaggedArray{_,__,RD}, src::AbstractRaggedArray, I...)
    N = length(I)
    quote
        D = eachindex(dest)
        Ds = start(D)
        @ragged_nloops $N $RD i dest d->(j_d = indexref(I[d], i_d)) begin
            d, Ds = next(D, Ds)
            v = @ncall $N ragged_unsafe_getindex src j
            setindex!(dest, v, d) # TODO: this can become unsafe once checksize is stricter
        end
        dest
    end
end

## Eachindex
# Doc: "If the arrays have different sizes and/or dimensionalities, eachindex
# returns an iterable that spans the largest range along each dimension."

Base.linearindexing(::RaggedFast, ::RaggedFast) = RaggedFast()
Base.linearindexing(::RaggedIndexing, ::RaggedIndexing) = RaggedSlow()
Base.linearindexing(::RaggedIndexing, ::Base.LinearIndexing) = Base.LinearSlow()
Base.linearindexing(::Base.LinearIndexing, ::RaggedIndexing) = Base.LinearSlow()

Base.linearindexing{R<:AbstractRaggedArray}(::Type{R}) = RaggedSlow()

# TODO: this can be done Cartesian-like *way* more efficiently. This is just
# a temporary stop-gap.
@inline cartidx(idxs...) = CartesianIndex(idxs)
@generated function Base.eachindex{T,N,RD}(::RaggedSlow, R::AbstractRaggedArray{T,N,RD})
    quote
        Is = Vector{CartesianIndex{$N}}(length(R))
        idx = 0
        @ragged_nloops $N $RD i R begin
            idx += 1
            Is[idx] = @ncall $N cartidx i
        end
        Is
    end
end
# TODO: extend to maximum of each dimension?  For now, just ensure sizes are equal and punt.
function Base.eachindex(::RaggedSlow, R::AbstractArray, Rs::AbstractArray...)
    sz = size(R)
    for r in Rs
        sz == size(r) || throw(DimensionMismatch())
    end
    eachindex(RaggedSlow(), R)
end
Base.eachindex(::RaggedSlow, A::AbstractArray) = eachindex(Base.LinearSlow(), A)
