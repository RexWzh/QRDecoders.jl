function randerr!(msgpoly::Poly, e::Int)
    errpos = sample(eachindex(msgpoly.coeff), e; replace=false)
    msgpoly.coeff[errpos] .⊻= rand(1:255, e)
    return msgpoly
end

function getecinfo(msg::AbstractString)
    mode, eclevel = getmode(msg), Medium()
    version = getversion(msg, mode, eclevel)
    ncodewords, nb1, _, nb2, _ = ecblockinfo[eclevel][version, :]
    return ncodewords, nb1 + nb2
end

function qrcode_with_maxerr(msg::AbstractString)
    ncodewords, nb = getecinfo(msg)
    return qrcode_with_randerr(msg, fill(ncodewords >> 1, nb))
end

function qrcode_with_randerr(msg::AbstractString)
    ncodewords, nb = getecinfo(msg)
    return qrcode_with_randerr(msg, [rand(1:ncodewords >> 1) for _ in 1:nb])
end

function qrcode_with_randerr(msg::AbstractString, err::Int)
    _, nb = getecinfo(msg)
    return qrcode_with_randerr(msg, fill(err, nb))
end

function qrcode_with_randerr(msg::AbstractString, errs::AbstractVector)::BitMatrix
    mode, eclevel = getmode(msg), Medium()
    version = getversion(msg, mode, eclevel)
    modeindicator = modeindicators[mode]
    msglen = mode != UTF8() ? length(msg) : utf8len(msg) ## utf-8 has flexialbe length
    ccindicator = getcharactercountindicator(msglen, version, mode)
    encodeddata = encodedata(msg, mode)
    ncodewords, nb1, nc1, nb2, nc2 = ecblockinfo[eclevel][version, :]
    requiredbits = 8 * (nb1 * nc1 + nb2 * nc2)
    encoded = vcat(modeindicator, ccindicator, encodeddata)
    encoded = padencodedmessage(encoded, requiredbits)
    # Getting error correction codes
    blocks = makeblocks(encoded, nb1, nc1, nb2, nc2)
    ecblocks = getecblock.(blocks, ncodewords)
    ## fill errors in each block/ecblock
    for (err, block, ecblock) in zip(errs, blocks, ecblocks)
        e1 = rand(0:err)
        eposofblock = sample(eachindex(block), e1; replace=false)
        block[eposofblock] .⊻= rand(1:255, e1)
        e2 = err - e1
        eposofecblock = sample(eachindex(ecblock), e2; replace=false)
        ecblock[eposofecblock] .⊻= rand(1:255, e2)
    end
    data = interleave(blocks, ecblocks, ncodewords, nb1, nc1, nb2, nc2, version)
    matrix = emptymatrix(version)
    # random mask
    maskind = rand(0:7)
    mask = makemask(matrix, maskind)
    matrix = placedata!(matrix, data) # fill in data bits
    addversion!(matrix, version) # fill in version bits
    return addformat!(xor.(matrix, mask), maskind, eclevel)
end

function exportfrommatrix(matrix::AbstractMatrix
                    , path::AbstractString = "qrcode.png"
                    ; targetsize::Int = 5
                    , compact::Bool = false
                    , scale::Real = 0)
    path = split(path, '.')[1] + ".png"
    if compact
        matrix = falses(size(matrix) .+ (8, 8))
        matrix[5:end-4, 5:end-4] = matrix
    end
    if iszero(scale)
        pixels = size(matrix, 1)
        scale = ceil(Int, 72 * targetsize / 2.45 / pixels)
    end
    matrix = kron(matrix, trues(scale, scale))
    save(path, BitArray(.! matrix))
end # module