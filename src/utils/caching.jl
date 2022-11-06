function enable_disk_caching(;
    membound=8 * (1024^3),
    diskpath=joinpath(MemPool.default_dir(), randstring(6)),
    diskbound=32 * (1024^3),
    kind="MRU"
)
    if !(kind in ("LRU", "MRU"))
        @warn "Unknown allocator kind: $kind\nDefaulting to MRU"
        kind = "MRU"
    end

    r = [
        remotecall(id) do
            MemPool.GLOBAL_DEVICE[] = MemPool.SimpleRecencyAllocator(
                membound,
                MemPool.SerializationFileDevice(MemPool.FilesystemResource(), joinpath(diskpath, "process_$id")),
                diskbound,
                Symbol(kind)
            )
            true
        end
        for id in procs()
    ]
    return all(fetch.(r))
end
