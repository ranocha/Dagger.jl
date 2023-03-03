export AnyScope, DefaultScope, UnionScope, NodeScope, ProcessScope, ExactScope, ProcessorTypeScope

abstract type AbstractScope end

"Widest scope that contains all processors."
struct AnyScope <: AbstractScope end

abstract type AbstractScopeTaint end

"Taints a scope for later evaluation."
struct TaintScope <: AbstractScope
    scope::AbstractScope
    taints::Set{AbstractScopeTaint}
end
Base.:(==)(ts1::TaintScope, ts2::TaintScope) =
    ts1.scope == ts2.scope &&
    length(ts1.taints) == length(ts2.taints) &&
    all(collect(ts1.taints) .== collect(ts2.taints))

struct DefaultEnabledTaint <: AbstractScopeTaint end

"Default scope that contains the set of `default_enabled` processors."
DefaultScope() = TaintScope(AnyScope(),
                            Set{AbstractScopeTaint}([DefaultEnabledTaint()]))

"Union of two or more scopes."
struct UnionScope <: AbstractScope
    scopes::Tuple
end
UnionScope(scopes...) = UnionScope((scopes...,))
UnionScope(scopes::Vector{<:AbstractScope}) = UnionScope((scopes...,))
UnionScope(s::AbstractScope) = UnionScope((s,))
UnionScope() = throw(ArgumentError("Cannot construct empty UnionScope"))

"Scoped to the same physical node."
struct NodeScope <: AbstractScope
    uuid::UUID
end
NodeScope() = NodeScope(SYSTEM_UUIDS[myid()])

"Scoped to the same OS process."
struct ProcessScope <: AbstractScope
    parent::NodeScope
    wid::Int
end
function ProcessScope(wid::Integer)
    if wid == myid()
        ProcessScope(NodeScope(), wid)
    else
        ProcessScope(NodeScope(system_uuid(wid)), wid)
    end
end
ProcessScope(p::OSProc) = ProcessScope(p.pid)
ProcessScope() = ProcessScope(myid())

"Scoped to any processor with a given supertype."
struct ProcessorTypeTaint{T} <: AbstractScopeTaint end

ProcessorTypeScope(T) =
    TaintScope(AnyScope(),
               Set{AbstractScopeTaint}([ProcessorTypeTaint{T}()]))

"Scoped to a specific processor."
struct ExactScope <: AbstractScope
    parent::ProcessScope
    processor::Processor
end
ExactScope(proc) = ExactScope(ProcessScope(get_parent(proc).pid), proc)

"Indicates that the applied scopes `x` and `y` are incompatible."
struct InvalidScope <: AbstractScope
    x::AbstractScope
    y::AbstractScope
end

# Show methods

function Base.show(io::IO, scope::UnionScope)
    indent = io isa IOContext ? get(io, :indent, 0) : 0
    println(io, "UnionScope:")
    indent += 2
    inner_io = IOContext(io, :indent => indent)
    for (idx, inner_scope) in enumerate(scope.scopes)
        print(io, " "^indent); print(inner_io, inner_scope)
        idx < length(scope.scopes) && println(io)
    end
end
function Base.show(io::IO, scope::TaintScope)
    indent = io isa IOContext ? get(io, :indent, 0) : 0
    println(io, "TaintScope:")
    indent += 2
    inner_io = IOContext(io, :indent => indent)
    print(io, " "^indent, "scope: "); println(inner_io, scope.scope)
    println(io, " "^indent, "taints: ")
    indent += 4
    inner_io = IOContext(io, :indent => indent)
    for (idx, taint) in enumerate(scope.taints)
        print(io, " "^indent); print(inner_io, taint)
        idx < length(scope.taints) && println(io)
    end
end
Base.show(io::IO, scope::NodeScope) =
    print(io, "NodeScope: node == $(scope.uuid)")
Base.show(io::IO, scope::ProcessScope) =
    print(io, "ProcessScope: worker == $(scope.wid)")
Base.show(io::IO, scope::ExactScope) =
    print(io, "ExactScope: processor == $(scope.processor)")

# Comparisons and constraint checking

constrain(x, y) = x < y ? constrain(y, x) : throw(MethodError(constrain, x, y))

Base.isless(::AnyScope, ::AnyScope) = false
Base.isless(::AnyScope, x) = false
Base.isless(x, ::AnyScope) = true
constrain(::AnyScope, ::AnyScope) = AnyScope()
constrain(::AnyScope, y) = y

# N.B. TaintScope taints constraining (until encountering an `ExactScope`) to
# allow lazy evaluation of the taint matching on the final processor
taint_match(::DefaultEnabledTaint, x::Processor) = default_enabled(x)
taint_match(::ProcessorTypeTaint{T}, x::Processor) where T = x isa T
Base.isless(::TaintScope, ::TaintScope) = false
Base.isless(::TaintScope, ::AnyScope) = true
Base.isless(::TaintScope, x) = false
Base.isless(x, ::TaintScope) = true
function constrain(x::TaintScope, y::TaintScope)
    scope = constrain(x.scope, y.scope)
    if scope isa InvalidScope
        return scope
    end
    taints = Set{AbstractScopeTaint}()
    for tx in x.taints
        push!(taints, tx)
    end
    for ty in y.taints
        push!(taints, ty)
    end
    return TaintScope(scope, taints)
end
function constrain(x::TaintScope, y)
    scope = constrain(x.scope, y)
    if scope isa InvalidScope
        return scope
    end
    return TaintScope(scope, x.taints)
end
function constrain(x::TaintScope, y::ExactScope)
    for taint in x.taints
        if !taint_match(taint, y.processor)
            return InvalidScope(x, y)
        end
    end
    return constrain(x.scope, y)
end

Base.isless(::UnionScope, ::UnionScope) = false
Base.isless(::UnionScope, ::TaintScope) = true
Base.isless(::UnionScope, ::AnyScope) = true
function constrain(x::UnionScope, y::UnionScope)
    zs = Vector{AbstractScope}()
    for xs in x.scopes
        for ys in y.scopes
            scope = constrain(xs, ys)
            scope isa InvalidScope && continue
            push!(zs, scope)
        end
    end
    isempty(zs) && return InvalidScope(x, y)
    UnionScope(zs)
end
constrain(x::UnionScope, y) = constrain(x, UnionScope((y,)))

Base.isless(::NodeScope, ::NodeScope) = false
Base.isless(::NodeScope, ::TaintScope) = true
Base.isless(::NodeScope, ::AnyScope) = true
constrain(x::NodeScope, y::NodeScope) =
    x == y ? y : InvalidScope(x, y)

Base.isless(::ProcessScope, ::ProcessScope) = false
Base.isless(::ProcessScope, ::NodeScope) = true
Base.isless(::ProcessScope, ::TaintScope) = true
Base.isless(::ProcessScope, ::AnyScope) = true
constrain(x::ProcessScope, y::ProcessScope) =
    x == y ? y : InvalidScope(x, y)
constrain(x::NodeScope, y::ProcessScope) =
    x == y.parent ? y : InvalidScope(x, y)

Base.isless(::ExactScope, ::ExactScope) = false
Base.isless(::ExactScope, ::ProcessScope) = true
Base.isless(::ExactScope, ::NodeScope) = true
Base.isless(::ExactScope, ::TaintScope) = true
Base.isless(::ExactScope, ::AnyScope) = true
constrain(x::ExactScope, y::ExactScope) =
    x == y ? y : InvalidScope(x, y)
constrain(x::ProcessScope, y::ExactScope) =
    x == y.parent ? y : InvalidScope(x, y)
constrain(x::NodeScope, y::ExactScope) =
    x == y.parent.parent ? y : InvalidScope(x, y)

### Scopes helper

function scope(scs...)
    if length(scs) == 0
        return AnyScope()
    elseif length(scs) == 1
        if only(scs) == :default
            return DefaultScope()
        else
            return to_scope(only(scs))
        end
    end
    return UnionScope(map(to_scope, scs))
end
function scope(; kwargs...)
    if length(kwargs) == 0
        return AnyScope()
    end
    return to_scope((;kwargs...))
end
to_scope(scope::AbstractScope) = scope
function to_scope(sc::NamedTuple)
    # FIXME: node and nodes
    known_keys = (:worker, :workers, :thread, :threads)
    unknown_keys = filter(key->!in(key, known_keys), keys(sc))
    if length(unknown_keys) > 0
        # Hand off construction if unknown members encountered
        precs = map(scope_key_precedence, map(Val, unknown_keys))
        max_prec = maximum(precs)
        if length(findall(prec->prec==max_prec, precs)) > 1
            throw(ArgumentError("Incompatible scope specifiers detected: $unknown_keys"))
        end
        max_prec_key = unknown_keys[argmax(precs)]
        return to_scope(Val(max_prec_key), sc)
    end

    workers = if haskey(sc, :worker)
        Int[sc.worker]
    elseif haskey(sc, :workers)
        Int[sc.workers...]
    else
        nothing
    end
    threads = if haskey(sc, :thread)
        Int[sc.thread]
    elseif haskey(sc, :threads)
        Int[sc.threads...]
    else
        nothing
    end

    # Simple cases
    if workers === nothing && threads === nothing
        return AnyScope()
    elseif workers !== nothing && threads !== nothing
        subscopes = AbstractScope[]
        for w in workers, t in threads
            push!(subscopes, ExactScope(ThreadProc(w, t)))
        end
        if length(subscopes) == 1
            return first(subscopes)
        end
        return UnionScope(subscopes)
    elseif workers !== nothing && threads === nothing
        subscopes = AbstractScope[ProcessScope(w) for w in workers]
        if length(subscopes) == 1
            return first(subscopes)
        end
        return UnionScope(subscopes)
    end

    # More complex cases that require querying the cluster
    # FIXME: Use per-field scope taint
    if workers === nothing
        workers = procs()
    end
    subscopes = AbstractScope[]
    for w in workers
        if threads === nothing
            threads = map(c->c.tid,
                          filter(c->c isa ThreadProc,
                                 collect(children(OSProc(w)))))
        end
        for t in threads
            push!(subscopes, ExactScope(ThreadProc(w, t)))
        end
    end
    if length(subscopes) == 1
        return first(subscopes)
    end
    return UnionScope(subscopes)
end
to_scope(scs::Tuple) =
    UnionScope(map(to_scope, scs))
to_scope(sc) =
    throw(ArgumentError("Cannot construct scope from: $sc"))

to_scope(::Val{key}, sc::NamedTuple) where key =
    throw(ArgumentError("Scope construction not implemented for key: $key"))

# Base case for all Dagger-owned keys
scope_key_precedence(::Val) = 0
