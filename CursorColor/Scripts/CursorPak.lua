--[[
    CursorPak: builds the small pak that holds the tinted cursors.

    Plain Lua 5.4, no game objects: it reads the game's own cursor images
    from the game's pak (Anvil-Windows.pak, pak version 11, not compressed,
    not encrypted), tints them, and writes them to a pak of the same
    version under the same paths, so the engine uses them instead.

    Build(GamePak, OutPath, R, G, B) returns true, or nil and an error.
--]]

local M = {}

-- The engine loads these at "Slate/<Name>" (Content\Slate\<Name>.png).
-- Paint = every pixel takes the colour (the aim ring is near black, a
-- multiply would leave it black); the others are multiplied, so white parts
-- take the colour and the dark outline stays dark.
M.Cursors = {
    { Name = "MouseCursor" },
    { Name = "MouseCursorSword" },
    { Name = "MouseCursorHammer" },
    { Name = "MouseCursorAiming" },
    { Name = "AimReticleCenter", Paint = true },
}

local Root = "Anvil/Content/Slate/"

------------------------------------------------------------------------
-- Checksums: CRC-32 (PNG chunks), Adler-32 (zlib), SHA-1 (pak hashes).
------------------------------------------------------------------------

local CrcTable = {}
for Index = 0, 255 do
    local Value = Index
    for _ = 1, 8 do
        if Value & 1 == 1 then Value = 0xEDB88320 ~ (Value >> 1) else Value = Value >> 1 end
    end
    CrcTable[Index] = Value
end

local function Crc32(Data)
    local Crc = 0xFFFFFFFF
    for Index = 1, #Data do
        Crc = CrcTable[(Crc ~ string.byte(Data, Index)) & 0xFF] ~ (Crc >> 8)
    end
    return Crc ~ 0xFFFFFFFF
end

local function Adler32(Data)
    local A, B = 1, 0
    for Index = 1, #Data do
        A = (A + string.byte(Data, Index)) % 65521
        B = (B + A) % 65521
    end
    return (B << 16) | A
end

local function Rol(Value, Bits)
    return ((Value << Bits) | (Value >> (32 - Bits))) & 0xFFFFFFFF
end

local function Sha1(Data)
    local H0, H1, H2, H3, H4 = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0
    local Length = #Data
    local Padded = Data .. "\x80" .. string.rep("\0", (55 - Length) % 64) .. string.pack(">I8", Length * 8)
    local W = {}
    for Block = 1, #Padded, 64 do
        for I = 0, 15 do W[I] = string.unpack(">I4", Padded, Block + I * 4) end
        for I = 16, 79 do W[I] = Rol(W[I - 3] ~ W[I - 8] ~ W[I - 14] ~ W[I - 16], 1) end
        local A, B, C, D, E = H0, H1, H2, H3, H4
        for I = 0, 79 do
            local F, K
            if I < 20 then F, K = (B & C) | ((~B) & D), 0x5A827999
            elseif I < 40 then F, K = B ~ C ~ D, 0x6ED9EBA1
            elseif I < 60 then F, K = (B & C) | (B & D) | (C & D), 0x8F1BBCDC
            else F, K = B ~ C ~ D, 0xCA62C1D6 end
            local T = (Rol(A, 5) + (F & 0xFFFFFFFF) + E + K + W[I]) & 0xFFFFFFFF
            A, B, C, D, E = T, A, Rol(B, 30), C, D
        end
        H0 = (H0 + A) & 0xFFFFFFFF
        H1 = (H1 + B) & 0xFFFFFFFF
        H2 = (H2 + C) & 0xFFFFFFFF
        H3 = (H3 + D) & 0xFFFFFFFF
        H4 = (H4 + E) & 0xFFFFFFFF
    end
    return string.pack(">I4I4I4I4I4", H0, H1, H2, H3, H4)
end
M.Sha1 = Sha1

------------------------------------------------------------------------
-- Inflate (zlib stream): stored, fixed and dynamic Huffman blocks.
------------------------------------------------------------------------

local LengthBase = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
local LengthExtra = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
local DistBase = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
    4097, 6145, 8193, 12289, 16385, 24577 }
local DistExtra = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
local CodeOrder = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

-- Canonical Huffman table from code lengths (Lengths[0..N-1]).
local function BuildHuffman(Lengths, N)
    local Count, Symbol, Offset = {}, {}, {}
    for Bits = 0, 15 do Count[Bits] = 0 end
    for Index = 0, N - 1 do Count[Lengths[Index]] = Count[Lengths[Index]] + 1 end
    Offset[1] = 0
    for Bits = 1, 14 do Offset[Bits + 1] = Offset[Bits] + Count[Bits] end
    for Index = 0, N - 1 do
        local Bits = Lengths[Index]
        if Bits ~= 0 then
            Symbol[Offset[Bits]] = Index
            Offset[Bits] = Offset[Bits] + 1
        end
    end
    return { Count = Count, Symbol = Symbol }
end

local function Inflate(Data)
    local Pos = 3 -- skip the 2-byte zlib header
    local BitBuffer, BitCount = 0, 0
    local Out, OutLen = {}, 0

    local function Bits(Need)
        while BitCount < Need do
            local Byte = string.byte(Data, Pos)
            if not Byte then error("inflate: data ended early") end
            Pos = Pos + 1
            BitBuffer = BitBuffer | (Byte << BitCount)
            BitCount = BitCount + 8
        end
        local Value = BitBuffer & ((1 << Need) - 1)
        BitBuffer = BitBuffer >> Need
        BitCount = BitCount - Need
        return Value
    end

    local function Decode(Table)
        local Code, First, Index = 0, 0, 0
        for Len = 1, 15 do
            Code = Code | Bits(1)
            local Count = Table.Count[Len]
            if Code - Count < First then return Table.Symbol[Index + (Code - First)] end
            Index = Index + Count
            First = (First + Count) << 1
            Code = Code << 1
        end
        error("inflate: bad code")
    end

    local function Codes(LenTable, DistTable)
        while true do
            local Sym = Decode(LenTable)
            if Sym < 256 then
                OutLen = OutLen + 1
                Out[OutLen] = Sym
            elseif Sym == 256 then
                return
            else
                Sym = Sym - 257
                if Sym >= 29 then error("inflate: bad length") end
                local Len = LengthBase[Sym + 1] + Bits(LengthExtra[Sym + 1])
                local DistSym = Decode(DistTable)
                if DistSym >= 30 then error("inflate: bad distance") end
                local Dist = DistBase[DistSym + 1] + Bits(DistExtra[DistSym + 1])
                if Dist > OutLen then error("inflate: distance too far") end
                for _ = 1, Len do
                    OutLen = OutLen + 1
                    Out[OutLen] = Out[OutLen - Dist]
                end
            end
        end
    end

    local FixedLen, FixedDist
    repeat
        local Last = Bits(1)
        local Type = Bits(2)
        if Type == 0 then
            BitBuffer, BitCount = 0, 0 -- to the next byte
            local Len, NLen = string.unpack("<I2I2", Data, Pos)
            if Len ~= (~NLen & 0xFFFF) then error("inflate: bad stored block") end
            Pos = Pos + 4
            for Index = Pos, Pos + Len - 1 do
                OutLen = OutLen + 1
                Out[OutLen] = string.byte(Data, Index)
            end
            Pos = Pos + Len
        elseif Type == 1 then
            if not FixedLen then
                local L = {}
                for I = 0, 143 do L[I] = 8 end
                for I = 144, 255 do L[I] = 9 end
                for I = 256, 279 do L[I] = 7 end
                for I = 280, 287 do L[I] = 8 end
                FixedLen = BuildHuffman(L, 288)
                local D = {}
                for I = 0, 29 do D[I] = 5 end
                FixedDist = BuildHuffman(D, 30)
            end
            Codes(FixedLen, FixedDist)
        elseif Type == 2 then
            local NLen, NDist, NCode = Bits(5) + 257, Bits(5) + 1, Bits(4) + 4
            local CodeLengths = {}
            for I = 0, 18 do CodeLengths[I] = 0 end
            for I = 1, NCode do CodeLengths[CodeOrder[I]] = Bits(3) end
            local CodeTable = BuildHuffman(CodeLengths, 19)
            local Lengths, Index = {}, 0
            while Index < NLen + NDist do
                local Sym = Decode(CodeTable)
                if Sym < 16 then
                    Lengths[Index] = Sym
                    Index = Index + 1
                else
                    local Value, Repeat = 0, 0
                    if Sym == 16 then
                        if Index == 0 then error("inflate: repeat with no length") end
                        Value, Repeat = Lengths[Index - 1], 3 + Bits(2)
                    elseif Sym == 17 then
                        Repeat = 3 + Bits(3)
                    else
                        Repeat = 11 + Bits(7)
                    end
                    for _ = 1, Repeat do
                        Lengths[Index] = Value
                        Index = Index + 1
                    end
                end
            end
            local LenLengths, DistLengths = {}, {}
            for I = 0, NLen - 1 do LenLengths[I] = Lengths[I] end
            for I = 0, NDist - 1 do DistLengths[I] = Lengths[NLen + I] end
            Codes(BuildHuffman(LenLengths, NLen), BuildHuffman(DistLengths, NDist))
        else
            error("inflate: bad block type")
        end
    until Last == 1

    local Parts = {}
    for Start = 1, OutLen, 4096 do
        Parts[#Parts + 1] = string.char(table.unpack(Out, Start, math.min(Start + 4095, OutLen)))
    end
    return table.concat(Parts)
end
M.Inflate = Inflate

------------------------------------------------------------------------
-- PNG (RGBA, 8 bits per channel, not interlaced).
------------------------------------------------------------------------

local PngSignature = "\x89PNG\r\n\x1a\n"

-- Returns width, height and a table of bytes (R, G, B, A per pixel).
local function DecodePng(Png)
    if string.sub(Png, 1, 8) ~= PngSignature then error("not a PNG") end
    local Pos, Width, Height = 9, nil, nil
    local Idat = {}
    while Pos <= #Png do
        local Length, Type = string.unpack(">I4c4", Png, Pos)
        local Body = string.sub(Png, Pos + 8, Pos + 7 + Length)
        if Type == "IHDR" then
            local Depth, Colour, Interlace
            Width, Height, Depth, Colour = string.unpack(">I4I4BB", Body)
            Interlace = string.byte(Body, 13)
            if Depth ~= 8 or Colour ~= 6 or Interlace ~= 0 then error("PNG is not 8-bit RGBA") end
        elseif Type == "IDAT" then
            Idat[#Idat + 1] = Body
        elseif Type == "IEND" then
            break
        end
        Pos = Pos + 12 + Length
    end
    if not Width then error("PNG has no header") end
    local Raw = Inflate(table.concat(Idat))
    local Stride = Width * 4
    if #Raw < Height * (Stride + 1) then error("PNG data too short") end
    local Px = {}
    for Y = 0, Height - 1 do
        local Filter = string.byte(Raw, Y * (Stride + 1) + 1)
        local Base = Y * (Stride + 1) + 1
        local Row = Y * Stride
        for X = 1, Stride do
            local Value = string.byte(Raw, Base + X)
            local Left = X > 4 and Px[Row + X - 4] or 0
            local Up = Y > 0 and Px[Row - Stride + X] or 0
            local UpLeft = (X > 4 and Y > 0) and Px[Row - Stride + X - 4] or 0
            if Filter == 1 then Value = Value + Left
            elseif Filter == 2 then Value = Value + Up
            elseif Filter == 3 then Value = Value + ((Left + Up) // 2)
            elseif Filter == 4 then
                local P = Left + Up - UpLeft
                local PA, PB, PC = math.abs(P - Left), math.abs(P - Up), math.abs(P - UpLeft)
                if PA <= PB and PA <= PC then Value = Value + Left
                elseif PB <= PC then Value = Value + Up
                else Value = Value + UpLeft end
            elseif Filter ~= 0 then
                error("PNG has an unknown filter")
            end
            Px[Row + X] = Value & 0xFF
        end
    end
    return Width, Height, Px
end
M.DecodePng = DecodePng

local function Chunk(Type, Body)
    return string.pack(">I4", #Body) .. Type .. Body .. string.pack(">I4", Crc32(Type .. Body))
end

-- Stored (uncompressed) deflate: the file size only depends on the image
-- size, so the pak has the same layout whatever the colour.
local function EncodePng(Width, Height, Px)
    local Rows = {}
    for Y = 0, Height - 1 do
        local Row = { 0 }
        for X = 1, Width * 4 do Row[X + 1] = Px[Y * Width * 4 + X] end
        Rows[#Rows + 1] = string.char(table.unpack(Row))
    end
    local Raw = table.concat(Rows)
    if #Raw > 65535 then error("image too large") end
    local Deflate = "\x78\x01\x01" .. string.pack("<I2I2", #Raw, (~#Raw) & 0xFFFF) .. Raw .. string.pack(">I4", Adler32(Raw))
    return PngSignature
        .. Chunk("IHDR", string.pack(">I4I4BBBBB", Width, Height, 8, 6, 0, 0, 0))
        .. Chunk("IDAT", Deflate)
        .. Chunk("IEND", "")
end
M.EncodePng = EncodePng

local function Clamp(Value)
    if Value < 0 then return 0 end
    if Value > 255 then return 255 end
    return Value
end

local function Tint(Px, R, G, B, Paint)
    local Out = {}
    local Colour = { R, G, B }
    for Index = 1, #Px, 4 do
        for Channel = 0, 2 do
            local Value = Paint and 255 or Px[Index + Channel]
            Out[Index + Channel] = Clamp(math.floor(Value * Colour[Channel + 1] + 0.5))
        end
        Out[Index + 3] = Px[Index + 3]
    end
    return Out
end
M.Tint = Tint

------------------------------------------------------------------------
-- Pak v11 reading (only what is needed to find a few files).
------------------------------------------------------------------------

local Magic = "\xE1\x12\x6F\x5A"

-- FNV-64 of the lowercased path (UTF-16LE), the pak's path hash. Lua
-- integers wrap around on overflow, as the hash needs.
local function PathHash(Path, Seed)
    local Hash = 0xcbf29ce484222325 + Seed
    local Lower = string.lower(Path)
    for Index = 1, #Lower do
        Hash = (Hash ~ string.byte(Lower, Index)) * 0x100000001b3
        Hash = (Hash ~ 0) * 0x100000001b3 -- the high byte of the UTF-16 character
    end
    return Hash
end
M.PathHash = PathHash

local function ReadAt(File, Offset, Length)
    File:seek("set", Offset)
    local Data = File:read(Length)
    if not Data or #Data ~= Length then error("pak read failed") end
    return Data
end

local function SkipFString(Data, Pos)
    local Length = string.unpack("<i4", Data, Pos)
    if Length >= 0 then return Pos + 4 + Length end
    return Pos + 4 - Length * 2
end

-- Returns a function Read(Path) giving the bytes of one of Paths (nil if
-- missing).
local function OpenPak(File, Paths)
    -- Version 11 footer: key GUID (16), encrypted flag (1), magic (4),
    -- version (4), index offset (8), index size (8), index hash (20),
    -- five compression method names (5 x 32): the magic is 204 bytes from
    -- the end.
    local Size = File:seek("end")
    if Size < 221 then error("not a pak (too small)") end
    local Tail = ReadAt(File, Size - 221, 221)
    local At = 18
    if string.sub(Tail, At, At + 3) ~= Magic then error("not a pak version 11 (no footer)") end
    local Version, IndexOffset, IndexSize = string.unpack("<I4i8i8", Tail, At + 4)
    if Version ~= 11 then error("unexpected pak version " .. Version) end
    if string.byte(Tail, At - 1) ~= 0 then error("pak index is encrypted") end

    local Index = ReadAt(File, IndexOffset, IndexSize)
    local Pos = SkipFString(Index, 1)
    local Seed
    Pos = Pos + 4 -- entry count
    Seed, Pos = string.unpack("<i8", Index, Pos)
    local HasPathHash
    HasPathHash, Pos = string.unpack("<I4", Index, Pos)
    if HasPathHash == 0 then error("pak has no path hash index") end
    local HashOffset, HashSize
    HashOffset, HashSize, Pos = string.unpack("<i8i8", Index, Pos)
    Pos = Pos + 20
    local HasDirectory
    HasDirectory, Pos = string.unpack("<I4", Index, Pos)
    if HasDirectory ~= 0 then Pos = Pos + 8 + 8 + 20 end
    local EncodedLength
    EncodedLength, Pos = string.unpack("<i4", Index, Pos)
    local Encoded = string.sub(Index, Pos, Pos + EncodedLength - 1)

    local Hashes = ReadAt(File, HashOffset, HashSize)
    local Count = string.unpack("<i4", Hashes, 1)

    -- One pass over the index for all the wanted paths.
    local Wanted, Locations, Left = {}, {}, 0
    for _, Path in ipairs(Paths) do
        Wanted[PathHash(Path, Seed)] = Path
        Left = Left + 1
    end
    for Entry = 0, Count - 1 do
        local Hash, Loc = string.unpack("<i8i4", Hashes, 5 + Entry * 12)
        local Path = Wanted[Hash]
        if Path and not Locations[Path] then
            Locations[Path] = Loc
            Left = Left - 1
            if Left == 0 then break end
        end
    end

    return function(Path)
        local Location = Locations[Path]
        if not Location or Location < 0 then return nil end
        local Flags, P = string.unpack("<I4", Encoded, Location + 1)
        if Flags & 0x3F == 0x3F then P = P + 4 end
        local Method = (Flags >> 23) & 0x3F
        local Encrypted = (Flags >> 22) & 1
        if Method ~= 0 or Encrypted ~= 0 then error(Path .. " is compressed or encrypted") end
        local Offset, Length
        if (Flags >> 31) & 1 == 1 then Offset, P = string.unpack("<I4", Encoded, P) else Offset, P = string.unpack("<i8", Encoded, P) end
        if (Flags >> 30) & 1 == 1 then Length, P = string.unpack("<I4", Encoded, P) else Length, P = string.unpack("<i8", Encoded, P) end
        -- The data follows its own entry header (53 bytes for an uncompressed entry).
        return ReadAt(File, Offset + 53, Length)
    end
end

------------------------------------------------------------------------
-- Pak v11 writing: uncompressed files, mount point ../../../.
------------------------------------------------------------------------

local function FString(Text)
    return string.pack("<i4", #Text + 1) .. Text .. "\0"
end

-- Files = list of { Path, Data }; returns the pak's bytes.
local function WritePak(Files)
    local Parts, Position = {}, 0
    local Encoded = {}
    local EncodedPosition = 0
    for _, File in ipairs(Files) do
        File.Offset = Position
        local Header = string.pack("<i8i8i8I4", 0, #File.Data, #File.Data, 0) .. Sha1(File.Data) .. "\0" .. string.pack("<I4", 0)
        Parts[#Parts + 1] = Header
        Parts[#Parts + 1] = File.Data
        Position = Position + #Header + #File.Data
        -- Offset, size and uncompressed size fit in 32 bits; no compression.
        local Entry = string.pack("<I4I4I4", 0xE0000000, File.Offset, #File.Data)
        File.Location = EncodedPosition
        Encoded[#Encoded + 1] = Entry
        EncodedPosition = EncodedPosition + #Entry
    end
    local EncodedData = table.concat(Encoded)
    local Seed = 0

    local Hashes = { string.pack("<i4", #Files) }
    for _, File in ipairs(Files) do Hashes[#Hashes + 1] = string.pack("<i8i4", PathHash(File.Path, Seed), File.Location) end
    Hashes[#Hashes + 1] = string.pack("<i4", 0) -- empty pruned directory index
    local HashData = table.concat(Hashes)

    -- Full directory index: every folder with its parents, "/" first.
    local Folders, Order = {}, {}
    local function AddFolder(Folder)
        if not Folders[Folder] then
            Folders[Folder] = {}
            Order[#Order + 1] = Folder
        end
    end
    AddFolder("/")
    for _, File in ipairs(Files) do
        local Folder = string.match(File.Path, "^(.*/)") or "/"
        local Prefix = ""
        for Part in string.gmatch(Folder, "[^/]+/") do
            Prefix = Prefix .. Part
            AddFolder(Prefix)
        end
        table.insert(Folders[Folder], File)
    end
    local Directory = { string.pack("<i4", #Order) }
    for _, Folder in ipairs(Order) do
        Directory[#Directory + 1] = FString(Folder) .. string.pack("<i4", #Folders[Folder])
        for _, File in ipairs(Folders[Folder]) do
            Directory[#Directory + 1] = FString(string.sub(File.Path, #Folder + 1)) .. string.pack("<i4", File.Location)
        end
    end
    local DirectoryData = table.concat(Directory)

    local DataEnd = Position
    local function Primary(HashOffset, DirectoryOffset)
        return FString("../../../") .. string.pack("<i4i8", #Files, Seed)
            .. string.pack("<I4i8i8", 1, HashOffset, #HashData) .. Sha1(HashData)
            .. string.pack("<I4i8i8", 1, DirectoryOffset, #DirectoryData) .. Sha1(DirectoryData)
            .. string.pack("<i4", #EncodedData) .. EncodedData
            .. string.pack("<i4", 0)
    end
    local PrimaryLength = #Primary(0, 0)
    local HashOffset = DataEnd + PrimaryLength
    local PrimaryData = Primary(HashOffset, HashOffset + #HashData)

    local Footer = string.rep("\0", 16) .. "\0" .. Magic .. string.pack("<I4i8i8", 11, DataEnd, #PrimaryData)
        .. Sha1(PrimaryData) .. string.rep("\0", 5 * 32)
    Parts[#Parts + 1] = PrimaryData
    Parts[#Parts + 1] = HashData
    Parts[#Parts + 1] = DirectoryData
    Parts[#Parts + 1] = Footer
    return table.concat(Parts)
end
M.WritePak = WritePak

------------------------------------------------------------------------

-- Returns the bytes of the tinted pak, or nil and an error.
function M.Make(GamePakPath, R, G, B)
    local Ok, Result = pcall(function()
        local File = io.open(GamePakPath, "rb")
        if not File then error("cannot open " .. GamePakPath) end
        local ReadOk, Files = pcall(function()
            local Paths = {}
            for _, Cursor in ipairs(M.Cursors) do Paths[#Paths + 1] = Root .. Cursor.Name .. ".png" end
            local Read = OpenPak(File, Paths)
            local List = {}
            for _, Cursor in ipairs(M.Cursors) do
                local Path = Root .. Cursor.Name .. ".png"
                local Png = Read(Path)
                if Png then
                    local Width, Height, Px = DecodePng(Png)
                    List[#List + 1] = { Path = Path, Data = EncodePng(Width, Height, Tint(Px, R, G, B, Cursor.Paint)) }
                end
            end
            return List
        end)
        File:close()
        if not ReadOk then error(Files, 0) end
        if #Files == 0 then error("no cursor image found in the game's pak") end
        return WritePak(Files)
    end)
    if Ok then return Result end
    return nil, tostring(Result)
end

return M
