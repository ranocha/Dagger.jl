function enable_disk_caching!(ram_percentage_limit::Int=30)
    processes = procs()

    process_info = [ id =>
        remotecall(id) do
            return (;
                total_memory=Sys.total_physical_memory(),
                hostname=gethostname(),
            )
        end
        for id in processes
    ]

    machines = Dict()
    for (id, info) in process_info
        key = fetch(info)
        machines[key] = push!(get(machines, key, Int[]), id)
    end

    mem_limits = Dict()
    for (info, ids) in machines
        for id in ids
            mem_limits[id] = info.total_memory * ram_percentage_limit ÷ length(ids)
        end
    end



    r = [
        remotecall(id) do
            MemPool.setup_global_device!(
                MemPool.DiskCacheConfig(;
                    toggle=true,
                    membound=mem_limits[id]
                )
            )
            true
        end
        for id in processes
    ]
    return all(fetch.(r))
end
