##########
# TArray #
##########

"""
    TArray{T}(dims, ...)

Implementation of data structures that automatically perform copy-on-write after task copying.

If current_task is an existing key in `s`, then return `s[current_task]`. Otherwise, return `s[current_task] = s[last_task]`.

Usage:

```julia
TArray(dim)
```

Example:

```julia
ta = TArray(4)              # init
for i in 1:4 ta[i] = i end  # assign
Array(ta)                   # convert to 4-element Array{Int64,1}: [1, 2, 3, 4]
```
"""
struct TArray{T,N} <: AbstractArray{T,N}
    orig_task :: Task
    TArray{T,N}() where {T,N} = new(_current_task())
end

TArray{T,1}(d::Integer) where T = TArray(T,  d)
TArray{T}(d::Integer...) where T = TArray(T, d)
TArray{T}(UndefInitializer, d::Integer...) where T = TArray(T, d)
TArray{T,N}(d::Integer...) where {T,N} = length(d)==N ? TArray(T,d) : error("Malformed dims")
TArray{T,N}(UndefInitializer, d::Integer...) where {T,N} = length(d)==N ? TArray(T,d) : error("Malformed dims")
TArray{T,N}(dim::NTuple{N,Int}) where {T,N} = TArray(T, dim)

function TArray(T::Type, dim)
    res = TArray{T,length(dim)}();
    n = n_copies()
    d = Array{T}(undef, dim)
    task_local_storage(objectid(res), (n,d))
    res
end

#
# Indexing Interface Implementation
#

function Base.getindex(S::TArray{T, N}, I::Vararg{Int,N}) where {T, N}
    d = obj_for_reading(S)
    return d[I...]
end

function Base.setindex!(S::TArray{T, N}, x, I::Vararg{Int,N}) where {T, N}
    d = obj_for_writing(S)
    d[I...] = x
end

function Base.push!(S::TArray{T}, x) where T
    d = obj_for_writing(S)
    push!(d, x)
end

function Base.pop!(S::TArray)
    d = obj_for_writing(S)
    pop!(d)
end

function Base.convert(::Type{TArray}, x::Array)
    res = TArray{typeof(x[1]), ndims(x)}();
    n   = n_copies()
    task_local_storage(objectid(res), (n, x))
    return res
end

function Base.convert(::Array, x::Type{TArray})
    d = obj_for_reading(x)
    c = deepcopy(d)
    return c
end

function Base.display(S::TArray)
    arr = S.orig_task.storage[objectid(S)][2]
    @warn "display(::TArray) prints the originating task's storage, " *
        "not the current task's storage. " *
        "Please use show(::TArray) to display the current task's version of a TArray."
    display(arr)
end

Base.show(io::IO, S::TArray) = Base.show(io::IO, obj_for_reading(S))

# Base.get(t::Task, S) = S
# Base.get(t::Task, S::TArray) = (t.storage[S.ref][2])
Base.get(S::TArray) = obj_for_reading(S)

##
# Iterator Interface
IteratorSize(::Type{TArray{T, N}}) where {T, N} = HasShape{N}()
IteratorEltype(::Type{TArray}) = HasEltype()

# Implements iterate, eltype, length, and size functions,
# as well as firstindex, lastindex, ndims, and axes
for F in (:iterate, :eltype, :length, :size,
          :firstindex, :lastindex, :ndims, :axes)
    @eval Base.$F(a::TArray, args...) = $F(get(a), args...)
end

#
# Similarity implementation
#

Base.similar(S::TArray) = tzeros(eltype(S), size(S))
Base.similar(S::TArray, ::Type{T}) where {T} = tzeros(T, size(S))
Base.similar(S::TArray, dims::Dims) = tzeros(eltype(S), dims)

##########
# tzeros #
##########

"""
     tzeros(dims, ...)

Construct a distributed array of zeros.
Trailing arguments are the same as those accepted by `TArray`.

```julia
tzeros(dim)
```

Example:

```julia
tz = tzeros(4) # construct
Array(tz)      # convert to 4-element Array{Int64,1}: [0, 0, 0, 0]
```
"""
function tzeros(T::Type, dim)
    res = TArray{T,length(dim)}();
    n = n_copies()
    d = zeros(T, dim)
    task_local_storage(objectid(res), (n, d))
    return res
end

tzeros(::Type{T}, d1::Integer, drest::Integer...) where T =
    tzeros(T, convert(Dims, tuple(d1, drest...)))
tzeros(d1::Integer, drest::Integer...) =
    tzeros(Float64, convert(Dims, tuple(d1, drest...)))
tzeros(d::Dims) = tzeros(Float64, d)

"""
     tfill(val, dim, ...)

Construct a TArray of a specified value.

```julia
tfill(val, dim)
```

Example:

```julia
tz = tfill(9.0, 4) # construct
Array(tz) # convert to 4-element Array{Float64,1}:  [9.0  9.0  9.0  9.0]
```
"""
function tfill(val::Real, dim)
    res = TArray{typeof(val), length(dim)}();
    n = n_copies()
    d = fill(val, dim)
    task_local_storage(objectid(res), (n, d))
    return res
end
