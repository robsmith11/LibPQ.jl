Tables.istable(::Type{<:Result}) = true
Tables.rowaccess(::Type{<:Result}) = true
Tables.rows(jl_result::Result) = jl_result

Base.eltype(jl_result::Result) = Row
Base.length(jl_result::Result) = num_rows(jl_result)

function Tables.schema(jl_result::Result)
    types = map(jl_result.not_null, column_types(jl_result)) do not_null, col_type
        not_null ? col_type : Union{col_type, Missing}
    end
    return Tables.Schema(map(Symbol, column_names(jl_result)), types)
end

function Base.iterate(jl_result::Result, (len, row)=(length(jl_result), 1))
    row > len && return nothing
    return Row(jl_result, row), (len, row + 1)
end

struct Row
    result::Result
    row::Int
end

result(pqrow::Row) = getfield(pqrow, :result)
row_number(pqrow::Row) = getfield(pqrow, :row)

Base.propertynames(r::Row) = column_names(getfield(r, :result))

function Base.getproperty(pqrow::Row, name::Symbol)
    jl_result = result(pqrow)
    row = row_number(pqrow)
    col = column_number(jl_result, name)
    return jl_result[row, col]
end

function Base.getindex(pqrow::Row, col::Integer)
    row = row_number(pqrow)
    return result(pqrow)[row, col]
end

Base.length(pqrow::Row) = num_columns(result(pqrow))

function Base.iterate(pqrow::Row, (len, col)=(length(pqrow), 1))
    col > len && return nothing
    return (result(pqrow)[row_number(pqrow), col], (len, col + 1))
end

"""
    LibPQ.load!(table, connection::LibPQ.Connection, query) -> LibPQ.Statement

Insert the data from `table` using `query`.
`query` will be prepared as a [`LibPQ.Statement`](@ref) and then [`execute`](@ref) is run
on every row of `table`.

For best performance, wrap the call to this function in a PostgreSQL transaction:

```jldoctest; setup = :(execute(conn, "CREATE TEMPORARY TABLE libpqjl_test (no_nulls varchar(10) PRIMARY KEY, yes_nulls varchar(10));"))
julia> execute(conn, "BEGIN;");

julia> LibPQ.load!(
           (no_nulls = ["foo", "baz"], yes_nulls = ["bar", missing]),
           conn,
           "INSERT INTO libpqjl_test (no_nulls, yes_nulls) VALUES (\\\$1, \\\$2);",
       );

julia> execute(conn, "COMMIT;");
```
"""
function load!(table::T, connection::Connection, query::AbstractString) where {T}
    rows = Tables.rows(table)
    stmt = prepare(connection, query)
    state = iterate(rows)
    state === nothing && return
    row, st = state
    names = propertynames(row)
    sch = Tables.Schema(names, nothing)
    parameters = Vector{Parameter}(undef, length(names))
    while true
        Tables.eachcolumn(sch, row) do val, col, nm
            parameters[col] = if ismissing(val)
                missing
            elseif val isa AbstractString
                convert(String, val)
            else
                string(val)
            end
        end
        close(execute(stmt, parameters; throw_error=true))
        state = iterate(rows, st)
        state === nothing && break
        row, st = state
    end
    return stmt
end
