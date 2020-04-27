# Utility function for self-copying mechanism

_current_task() = ccall((:vanilla_get_current_task, libtask), Ref{Task}, ())

n_copies() = n_copies(_current_task())
n_copies(t::Task) = begin
  isa(t.storage, Nothing) && (t.storage = IdDict())
  if haskey(t.storage, :n_copies)
    t.storage[:n_copies]
  else
    t.storage[:n_copies] = 0
  end
end

function enable_stack_copying(t::Task)
    t.state != :runnable && t.state != :done &&
        error("Only runnable or finished tasks' stack can be copied.")
    return ccall((:jl_enable_stack_copying, libtask), Any, (Any,), t)::Task
end

"""

    task_wrapper()

`task_wrapper` is a wordaround for set the result/exception to the
correct task which maybe copied/forked from another one(the original
one). Without this, the result/exception is always sent to the
original task. That is done in `JULIA_PROJECT/src/task.c`, the
function `start_task` and `finish_task`.

This workaround is not the proper way to do the work it does. The
proper way is refreshing the `current_task` (the variable `t`) in
`start_task` after the call to `jl_apply` returns.

"""
function task_wrapper(func; _cow=true)
    () ->
    try
        ct = _current_task()
        res = _cow ? cow(func) : func()
        ct.result = res
        isa(ct.storage, Nothing) && (ct.storage = IdDict())
        ct.storage[:_libtask_state] = :done
        wait()
    catch ex
        ct = _current_task()
        ct.exception = ex
        ct.result = ex
        ct.backtrace = catch_backtrace()
        isa(ct.storage, Nothing) && (ct.storage = IdDict())
        ct.storage[:_libtask_state] = :failed
        wait()
    end
end

CTask(func; cow=true) = Task(task_wrapper(func, _cow=cow)) |> enable_stack_copying

function Base.copy(t::Task)
  t.state != :runnable && t.state != :done &&
    error("Only runnable or finished tasks can be copied.")
  newt = ccall((:jl_clone_task, libtask), Any, (Any,), t)::Task
  if t.storage != nothing
    n = n_copies(t)
    t.storage[:n_copies]  = 1 + n
    newt.storage = copy(t.storage)
  else
    newt.storage = nothing
  end
  # copy fields not accessible in task.c
  newt.code = t.code
  newt.state = t.state
  newt.result = t.result
  @static if VERSION < v"1.1"
    newt.parent = t.parent
  end
  if :last in fieldnames(typeof(t))
    newt.last = nothing
  end
  newt
end

struct CTaskException
    etype
    msg::String
    backtrace::Vector{Union{Ptr{Nothing}, Base.InterpreterIP}}
end

function Base.show(io::IO, exc::CTaskException)
    println(io, "Stacktrace in the failed task:\n")
    println(io, exc.msg * "\n")
    for line in stacktrace(exc.backtrace)
        println(io, string(line))
    end
end

produce(v) = begin
    ct = _current_task()

    if ct.storage == nothing
        ct.storage = IdDict()
    end

    haskey(ct.storage, :consumers) || (ct.storage[:consumers] = nothing)
    local empty, t, q
    while true
        q = ct.storage[:consumers]
        if isa(q,Task)
            t = q
            ct.storage[:consumers] = nothing
            empty = true
            break
        elseif isa(q,Condition) && !isempty(q.waitq)
            t = popfirst!(q.waitq)
            empty = isempty(q.waitq)
            break
        end
        wait()
    end

    if !(t.state in [:runnable, :queued])
        throw(AssertionError("producer.consumer.state in [:runnable, :queued]"))
    end
    @static if VERSION < v"1.1.9999"
        if t.state == :queued yield() end
    else
        if t.queue != nothing yield() end
    end
    if empty
        schedule(t, v)
        wait()
        ct = _current_task() # When a task is copied, ct should be updated to new task ID.
        while true
            # wait until there are more consumers
            q = ct.storage[:consumers]
            if isa(q,Task)
                return q.result
            elseif isa(q,Condition) && !isempty(q.waitq)
                return q.waitq[1].result
            end
            wait()
        end
    else
        schedule(t, v)
        # make sure `t` runs before us. otherwise, the producer might
        # finish before `t` runs again, causing it to see the producer
        # as done, causing done(::Task, _) to miss the value `v`.
        # see issue #7727
        yield()
        return q.waitq[1].result
    end
end

consume(p::Task, values...) = begin

    if p.storage == nothing
        p.storage = IdDict()
    end
    haskey(p.storage, :consumers) || (p.storage[:consumers] = nothing)

    if istaskdone(p)
        return wait(p)
    end

    ct = _current_task()
    ct.result = length(values)==1 ? values[1] : values

    #### un-optimized version
    #if P.consumers === nothing
    #    P.consumers = Condition()
    #end
    #push!(P.consumers.waitq, ct)
    # optimized version that avoids the queue for 1 consumer
    consumers = p.storage[:consumers]
    if consumers === nothing || (isa(consumers,Condition)&&isempty(consumers.waitq))
        p.storage[:consumers] = ct
    else
        if isa(consumers, Task)
            t = consumers
            p.storage[:consumers] = Condition()
            push!(p.storage[:consumers].waitq, t)
        end
        push!(p.storage[:consumers].waitq, ct)
    end

    if p.state == :runnable
        Base.schedule(p)
        yield()

        isa(p.storage, IdDict) && haskey(p.storage, :_libtask_state) &&
            (p.state = p.storage[:_libtask_state])

        if p.state == :done
            return p.result
        end
        if p.exception != nothing
            msg = if :msg in fieldnames(typeof(p.exception))
                p.exception.msg
            else
                string(typeof(p.exception))
            end
            throw(CTaskException(typeof(p.exception), msg, p.backtrace))
        end
    end
    wait()
end
