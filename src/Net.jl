import Base: UInt64, convert
using Dates

# ============================================================================ #
# [Constants]                                                                  #
# ============================================================================ #

const CLIENT_NAME = "ClickHouseJL"
const DBMS_VER_MAJOR = 19
const DBMS_VER_MINOR = 11
const DBMS_VER_REV = 54423

# ============================================================================ #
# [Context structs]                                                            #
# ============================================================================ #

"ClickHouse client socket. Created using `connect`."
mutable struct ClickHouseSock
    io::IO
    server_tz::Union{String, Nothing}
    stringify_enums::Bool
    dirty::Bool
    client_info

    function ClickHouseSock(io::IO)::ClickHouseSock
        new(
            io,
            nothing,
            true,
            false,
            ClientInfo(
                0x01,
                "",
                "",
                "0.0.0.0:0",
                0x01,
                "",
                "",
                CLIENT_NAME,
                DBMS_VER_MAJOR,
                DBMS_VER_MINOR,
                DBMS_VER_REV,
                "",
                2,
            ),
        )
    end
end

# ============================================================================ #
# [Variable length integer]                                                    #
# ============================================================================ #

primitive type VarUInt <: Unsigned 64 end

VarUInt(x::Number) = reinterpret(VarUInt, UInt64(x))
UInt64(x::VarUInt) = reinterpret(UInt64, x)
Base.show(io::IO, x::VarUInt) = print(io, UInt64(x))

function chwrite(sock::ClickHouseSock, x::VarUInt)
    mx::UInt64 = x
    while mx >= 0x80
        write(sock.io, UInt8(mx & 0xFF) | 0x80)
        mx >>= 7
    end
    write(sock.io, UInt8(mx & 0xFF))
end

function chread(sock::ClickHouseSock, ::Type{VarUInt})::VarUInt
    x::UInt64 = 0
    s::UInt32 = 0
    i::UInt64 = 0
    while true
        b = read(sock.io, UInt8)
        if b < 0x80
            if i > 9 || (i == 9 && b > 1)
                throw(OverflowError("varint would overflow"))
            end
            return x | UInt64(b) << s
        end

        x |= UInt64(b & 0x7F) << s
        s += 7
        i += 1
    end
end

# ============================================================================ #
# [chread impls for primitive types]                                           #
# ============================================================================ #

# Scalar reads
chread(sock::ClickHouseSock, ::Type{T}) where T <: Number =
    read(sock.io, T)

chread(sock::ClickHouseSock, x::UInt64)::Vector{UInt8} =
    read(sock.io, x)

function chread(sock::ClickHouseSock, ::Type{String})::String
    len = chread(sock, VarUInt) |> UInt64
    chread(sock, len) |> String
end

# Vector reads
function chread(
    sock::ClickHouseSock,
    ::Type{Vector{T}},
    count::VarUInt,
)::Vector{T} where T <: Number
    data = Vector{T}(undef, UInt64(count))
    read!(sock.io, data)
    data
end

chread(
    sock::ClickHouseSock,
    ::Type{Vector{String}},
    count::VarUInt,
)::Vector{String} = [chread(sock, String) for _ ∈ 1:UInt64(count)]

# ============================================================================ #
# [chwrite impls for primitive types]                                          #
# ============================================================================ #

# Scalar writes
chwrite(sock::ClickHouseSock, x::Number) =
    write(sock.io, x)

function chwrite(sock::ClickHouseSock, x::String)
    chwrite(sock, x |> length |> VarUInt)
    chwrite(sock, x |> Array{UInt8})
end

# Vector writes
chwrite(sock::ClickHouseSock, x::AbstractVector{T}) where T <: Number =
    write(sock.io, x)

chwrite(sock::ClickHouseSock, x::AbstractVector{String}) =
    foreach(x -> chwrite(sock, x), x)

# ============================================================================ #
# [Parse helpers]                                                              #
# ============================================================================ #

function impl_chread_for_ty(ty::Type)::Function
    arg_exprs = [:(chread(sock, $ty)) for ty ∈ ty.types]
    sym = split(ty.name |> string, '.')[end] |> Symbol
    reader = quote
        function chread(sock::ClickHouseSock, ::Type{$sym})::$sym
            $ty($(arg_exprs...))
        end
    end
    eval(reader)
end

function impl_chwrite_for_ty(ty::Type)::Function
    write_stmts = [:(chwrite(sock, x.$name)) for name ∈ fieldnames(ty)]
    writer = quote
        function chwrite(sock::ClickHouseSock, x::$(ty))
            $(write_stmts...)
        end
    end
    eval(writer)
end

# ============================================================================ #
# [Shared messages (wire format)]                                              #
# ============================================================================ #

const BLOCK_INFO_FIELD_STOP = UInt64(0)
const BLOCK_INFO_FIELD_OVERFLOWS = UInt64(1)
const BLOCK_INFO_FIELD_BUCKET_NUM = UInt64(2)

struct BlockInfo
    is_overflows::Bool
    bucket_num::Int32

    BlockInfo() = new(false, -1)
    BlockInfo(is_overflows, bucket_num) = new(is_overflows, bucket_num)
end

function chread(sock::ClickHouseSock, ::Type{BlockInfo})::BlockInfo
    is_overflows = false
    bucket_num = -1

    while (field_num = UInt64(chread(sock, VarUInt))) != BLOCK_INFO_FIELD_STOP
        if field_num == BLOCK_INFO_FIELD_OVERFLOWS
            is_overflows = chread(sock, Bool)
        elseif field_num == BLOCK_INFO_FIELD_BUCKET_NUM
            bucket_num = chread(sock, Int32)
        else
            throw("Unknown block info field")
        end
    end

    BlockInfo(is_overflows, bucket_num)
end

function chwrite(sock::ClickHouseSock, x::BlockInfo)
    # This mirrors what the C++ client does.
    chwrite(sock, VarUInt(BLOCK_INFO_FIELD_OVERFLOWS))
    chwrite(sock, x.is_overflows)
    chwrite(sock, VarUInt(BLOCK_INFO_FIELD_BUCKET_NUM))
    chwrite(sock, x.bucket_num)
    chwrite(sock, VarUInt(BLOCK_INFO_FIELD_STOP))
end

struct Column
    name::String
    type::String
    data::Any
end

const COL_TYPE_MAP = Dict(
    # Unsigned
    "UInt8"    => UInt8,
    "UInt16"   => UInt16,
    "UInt32"   => UInt32,
    "UInt64"   => UInt64,

    # Signed
    "Int8"     => Int8,
    "Int16"    => Int16,
    "Int32"    => Int32,
    "Int64"    => Int64,

    # Floats
    "Float32"  => Float32,
    "Float64"  => Float64,

    "String"   => String,

    "DateTime" => Int32,
    "Date"     => Int16,
)

const COL_TYPE_REV_MAP = Dict(v => k for (k, v) ∈ COL_TYPE_MAP)
const SECS_IN_DAY = 24 * 60 * 60

const ENUM_RE_OUTER = r"Enum(\d{1,2})\(\s*(.*)\)$"
const ENUM_RE_INNER = r"""
    (?:
    '((?:(?:[^'])|(?:\\'))+)'
    \s*=\s*
    (-?\d+)
    \s*,?\s*
    )+?
"""x

function parse_enum_def(str::String)
    def = match(ENUM_RE_OUTER, str)
    matches = eachmatch(ENUM_RE_INNER, def[2])
    map = Dict(x[1] => parse(Int64, x[2]) for x ∈ matches)
    type = "Int" * def[1]
    type, map
end

# We can't just use chread here because we need the size to be passed
# in from the `Block` decoder that holds the row count.
function read_col(sock::ClickHouseSock, num_rows::VarUInt)::Column
    name = chread(sock, String)
    type_name = chread(sock, String)

    decode_type_name, enum_def = if startswith(type_name, "Enum")
        parse_enum_def(type_name)
    else
        type_name, nothing
    end

    decode_type = try
        COL_TYPE_MAP[decode_type_name]
    catch exc
        if exc isa KeyError
            error("Unsupported data type: $(decode_type_name)")
        end
        rethrow()
    end

    data = chread(sock, Vector{decode_type}, num_rows)

    if type_name == "DateTime"
        data = unix2datetime.(data)
    elseif type_name == "Date"
        data = convert(Array{Int64}, data)
        data .*= SECS_IN_DAY
        data = unix2datetime.(data)
    elseif sock.stringify_enums && startswith(type_name, "Enum")
        imap = Dict(v => k for (k, v) ∈ enum_def)
        data = [imap[x] for x ∈ data]
    end

    Column(name, type_name, data)
end

function chwrite(sock::ClickHouseSock, x::Column)
    chwrite(sock, x.name)
    chwrite(sock, x.type)

    data = if x.type == "DateTime"
        d = datetime2unix.(x.data)
        d = round.(d)
        d = convert(Array{Int32}, d)
    elseif x.type == "Date"
        d = datetime2unix.(x.data)
        d ./= convert(Float64, SECS_IN_DAY)
        d = round.(d)
        d = convert(Array{Int16}, d)
    elseif sock.stringify_enums && startswith(x.type, "Enum")
        ty, map = parse_enum_def(x.type)
        d = [map[x] for x ∈ x.data]
        ty = COL_TYPE_MAP[ty]
        convert(Array{ty}, d)
    else
        x.data
    end

    chwrite(sock, data)
end

struct Block
    temp_table::String
    block_info::BlockInfo
    num_columns::VarUInt
    num_rows::VarUInt
    columns::Array{Column}
end

function chread(sock::ClickHouseSock, ::Type{Block})::Block
    temp_table = chread(sock, String)
    block_info = chread(sock, BlockInfo)
    num_columns = chread(sock, VarUInt)
    num_rows = chread(sock, VarUInt)
    columns = [read_col(sock, num_rows) for _ ∈ 1:UInt64(num_columns)]
    Block(temp_table, block_info, num_columns, num_rows, columns)
end

function chwrite(sock::ClickHouseSock, x::Block)
    chwrite(sock, x.temp_table)
    chwrite(sock, x.block_info)
    chwrite(sock, x.num_columns)
    chwrite(sock, x.num_rows)
    for x ∈ x.columns
        chwrite(sock, x)
    end
end

# ============================================================================ #
# [Server messages (wire format)]                                              #
# ============================================================================ #

struct ServerInfo
    server_name::String
    server_major_ver::VarUInt
    server_minor_ver::VarUInt
    server_rev::VarUInt

    # DBMS_MIN_REVISION_WITH_SERVER_TIMEZONE
    server_timezone::String

    # DBMS_MIN_REVISION_WITH_SERVER_DISPLAY_NAME
    server_display_name::String

    # DBMS_MIN_REVISION_WITH_VERSION_PATCH
    server_version_patch::VarUInt
end

impl_chread_for_ty(ServerInfo)

struct ServerPong
end

impl_chread_for_ty(ServerPong)

struct ServerProgress
    rows::VarUInt
    bytes::VarUInt
    total_rows::VarUInt

    # DBMS_MIN_REVISION_WITH_CLIENT_WRITE_INFO
    written_rows::VarUInt
    written_bytes::VarUInt
end

impl_chread_for_ty(ServerProgress)

struct ServerProfileInfo
    rows::VarUInt
    blocks::VarUInt
    bytes::VarUInt
    applied_limit::Bool
    rows_before_limit::VarUInt
    calc_rows_before_limit::Bool
end

impl_chread_for_ty(ServerProfileInfo)

struct ServerException
    code::UInt32
    name::String
    message::String
    stack_trace::String
    nested::Union{Nothing, ServerException}
end

function chread(sock::ClickHouseSock, ::Type{ServerException})::ServerException
    code = chread(sock, UInt32)
    name = chread(sock, String)
    message = chread(sock, String)
    stack_trace = chread(sock, String)
    has_nested = chread(sock, Bool)
    nested = has_nested ? chread(sock, ServerException) : nothing
    ServerException(code, name, message, stack_trace, nested)
end

struct ServerEndOfStream
end

impl_chread_for_ty(ServerEndOfStream)

struct ServerTableColumns
    external_table_name::String
    columns::String
    sample_block::Block
end

impl_chread_for_ty(ServerTableColumns)

# ============================================================================ #
# [Client messages (wire format)]                                              #
# ============================================================================ #

struct ClientHello
    client_name::String
    client_dbms_ver_major::VarUInt
    client_dbms_ver_minor::VarUInt
    client_dbms_ver_rev::VarUInt
    database::String
    username::String
    password::String
end

impl_chwrite_for_ty(ClientHello)
impl_chread_for_ty(ClientHello)

struct ClientPing
end

impl_chwrite_for_ty(ClientPing)
impl_chread_for_ty(ClientPing)

struct ClientInfo
    query_kind::UInt8
    initial_user::String
    initial_query_id::String
    initial_address_string::String
    read_interface::UInt8
    os_user::String
    client_hostname::String
    client_name::String
    client_ver_major::VarUInt
    client_ver_minor::VarUInt
    client_rev::VarUInt
    quota_key::String # DBMS_MIN_REVISION_WITH_QUOTA_KEY_IN_CLIENT_INFO
    client_ver_patch::VarUInt # DBMS_MIN_REVISION_WITH_VERSION_PATCH
end

impl_chwrite_for_ty(ClientInfo)
impl_chread_for_ty(ClientInfo)

struct ClientQuery
    query_id::String
    client_info::ClientInfo
    settings::String
    query_stage::VarUInt
    compression::VarUInt
    query::String
end

impl_chwrite_for_ty(ClientQuery)
impl_chread_for_ty(ClientQuery)

# ============================================================================ #
# [Opcodes]                                                                    #
# ============================================================================ #

const CLIENT_HELLO = UInt64(0)
const CLIENT_QUERY = UInt64(1)
const CLIENT_DATA = UInt64(2)
const CLIENT_CANCEL = UInt64(3)
const CLIENT_PING = UInt64(4)
const CLIENT_TABLE_STATUS_REQ = UInt64(5)
const CLIENT_KEEP_ALIVE = UInt64(6)

const SERVER_HELLO = UInt64(0)
const SERVER_DATA = UInt64(1)
const SERVER_EXCEPTION = UInt64(2)
const SERVER_PROGRESS = UInt64(3)
const SERVER_PONG = UInt64(4)
const SERVER_END_OF_STREAM = UInt64(5)
const SERVER_PROFILE_INFO = UInt64(6)
const SERVER_TOTALS = UInt64(7)
const SERVER_EXTREMES = UInt64(8)
const SERVER_TABLES_STATUS_REPORT = UInt64(9)
const SERVER_TABLES_LOG = UInt64(10)
const SERVER_TABLE_COLUMNS = UInt64(11)

# ============================================================================ #
# [Message decoding]                                                           #
# ============================================================================ #

const SERVER_OPCODE_TY_MAP = Dict(
    SERVER_HELLO => ServerInfo,
    SERVER_PONG => ServerPong,
    SERVER_PROGRESS => ServerProgress,
    SERVER_PROFILE_INFO => ServerProfileInfo,
    SERVER_EXCEPTION => ServerException,
    SERVER_DATA => Block,
    SERVER_TOTALS => Block,
    SERVER_EXTREMES => Block,
    SERVER_TABLE_COLUMNS => ServerTableColumns,
    SERVER_END_OF_STREAM => ServerEndOfStream,
)

const CLIENT_OPCODE_TY_MAP = Dict(
    CLIENT_HELLO => ClientHello,
    CLIENT_QUERY => ClientQuery,
    CLIENT_DATA => Block,
    CLIENT_PING => ClientPing,
)

function read_packet(
    sock::ClickHouseSock,
    opcode_map::Dict{UInt64, DataType},
)::Any
    opcode = chread(sock, VarUInt)
    ty = opcode_map[UInt64(opcode)]
    chread(sock, ty)
end

"ClickHouse server-side exception."
struct ClickHouseServerException <: Exception
    exc::ServerException
end

read_client_packet(sock::ClickHouseSock)::Any =
    read_packet(sock, CLIENT_OPCODE_TY_MAP)

function read_server_packet(sock::ClickHouseSock)::Any
    packet = read_packet(sock, SERVER_OPCODE_TY_MAP)

    if typeof(packet) == ServerException
        throw(ClickHouseServerException(packet))
    end

    packet
end

# ============================================================================ #
# [Message encoding]                                                           #
# ============================================================================ #

const CLIENT_TY_OPCODE_MAP = Dict(v => k for (k, v) ∈ CLIENT_OPCODE_TY_MAP)

function write_packet(sock::ClickHouseSock, packet::Any)
    opcode = CLIENT_TY_OPCODE_MAP[typeof(packet)]
    chwrite(sock, VarUInt(opcode))
    chwrite(sock, packet)
end

# ============================================================================ #
