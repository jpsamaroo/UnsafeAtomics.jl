@inline UnsafeAtomics.load(x) = UnsafeAtomics.load(x, seq_cst)
@inline UnsafeAtomics.store!(x, v) = UnsafeAtomics.store!(x, v, seq_cst)
@inline UnsafeAtomics.cas!(x, cmp, new) = UnsafeAtomics.cas!(x, cmp, new, seq_cst, seq_cst)
@inline UnsafeAtomics.modify!(ptr, op, x) = UnsafeAtomics.modify!(ptr, op, x, seq_cst)

right(_, x) = x

const OP_RMW_TABLE = [
    (+) => :add,
    (-) => :sub,
    right => :xchg,
    (&) => :and,
    (⊼) => :nand,
    (|) => :or,
    (⊻) => xor,
    max => :max,
    min => :min,
]

for (op, rmwop) in OP_RMW_TABLE
    fn = Symbol(rmwop, "!")
    @eval @inline UnsafeAtomics.$fn(x, v) = UnsafeAtomics.$fn(x, v, seq_cst)
    @eval @inline function UnsafeAtomics.modify!(ptr, ::typeof($op), x, ord)
        old = UnsafeAtomics.$fn(ptr, x, ord)
        return old, $op(old, x)
    end
end

for typ in inttypes
    lt = llvmtypes[typ]
    rt = "$lt, $lt*"

    for ord in orderings
        ord in (release, acq_rel) && continue

        @eval function UnsafeAtomics.load(x::Ptr{$typ}, ::$(typeof(ord)))
            return llvmcall(
                $("""
                %ptr = inttoptr i$WORD_SIZE %0 to $lt*
                %rv = load atomic $rt %ptr $ord, align $(sizeof(typ))
                ret $lt %rv
                """),
                $typ,
                Tuple{Ptr{$typ}},
                x,
            )
        end
    end

    for ord in orderings
        ord in (acquire, acq_rel) && continue

        @eval function UnsafeAtomics.store!(x::Ptr{$typ}, v::$typ, ::$(typeof(ord)))
            return llvmcall(
                $("""
                %ptr = inttoptr i$WORD_SIZE %0 to $lt*
                store atomic $lt %1, $lt* %ptr $ord, align $(sizeof(typ))
                ret void
                """),
                Cvoid,
                Tuple{Ptr{$typ},$typ},
                x,
                v,
            )
        end
    end

    for success_ordering in (monotonic, acquire, release, acq_rel, seq_cst),
        failure_ordering in (monotonic, acquire, seq_cst)

        @eval function UnsafeAtomics.cas!(
            x::Ptr{$typ},
            cmp::$typ,
            new::$typ,
            ::$(typeof(success_ordering)),
            ::$(typeof(failure_ordering)),
        )
            success = Ref{Int8}()
            GC.@preserve success begin
                old = llvmcall(
                    $(
                        """
                        %ptr = inttoptr i$WORD_SIZE %0 to $lt*
                        %rs = cmpxchg $lt* %ptr, $lt %1, $lt %2 $success_ordering $failure_ordering
                        %rv = extractvalue { $lt, i1 } %rs, 0
                        %s1 = extractvalue { $lt, i1 } %rs, 1
                        %s8 = zext i1 %s1 to i8
                        %sptr = inttoptr i$WORD_SIZE %3 to i8*
                        store i8 %s8, i8* %sptr
                        ret $lt %rv
                        """
                    ),
                    $typ,
                    Tuple{Ptr{$typ},$typ,$typ,Ptr{Int8}},
                    x,
                    cmp,
                    new,
                    Ptr{Int8}(pointer_from_objref(success)),
                )
            end
            return (old = old, success = !iszero(success[]))
        end
    end

    for rmwop in [:add, :sub, :xchg, :and, :nand, :or, :xor, :max, :min]
        rmw = string(rmwop)
        fn = Symbol(rmw, "!")
        if (rmw == "max" || rmw == "min") && typ <: Unsigned
            # LLVM distinguishes signedness in the operation, not the integer type.
            rmw = "u" * rmw
        end
        for ord in orderings
            @eval function UnsafeAtomics.$fn(x::Ptr{$typ}, v::$typ, ::$(typeof(ord)))
                return llvmcall(
                    $("""
                    %ptr = inttoptr i$WORD_SIZE %0 to $lt*
                    %rv = atomicrmw $rmw $lt* %ptr, $lt %1 $ord
                    ret $lt %rv
                    """),
                    $typ,
                    Tuple{Ptr{$typ},$typ},
                    x,
                    v,
                )
            end
        end
    end

end