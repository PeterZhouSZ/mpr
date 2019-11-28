#include <cassert>
#include "renderable.hpp"

////////////////////////////////////////////////////////////////////////////////

template <typename R, unsigned T, unsigned D>
__device__ void storeAxes(const uint32_t tile,
                          const View& v, const Tiles<T, D>& tiles, const Tape& tape,
                          R* const __restrict__ regs)
{
   // Prepopulate axis values
    const float3 lower = tiles.tileToLowerPos(tile);
    const float3 upper = tiles.tileToUpperPos(tile);

    Interval X(lower.x, upper.x);
    Interval Y(lower.y, upper.y);
    Interval Z(lower.z, upper.z);

    if (tape.axes.reg[0] != UINT16_MAX) {
        regs[tape.axes.reg[0]] = X * v.scale - v.center[0];
    }
    if (tape.axes.reg[1] != UINT16_MAX) {
        regs[tape.axes.reg[1]] = Y * v.scale - v.center[1];
    }
    if (tape.axes.reg[2] != UINT16_MAX) {
        regs[tape.axes.reg[2]] = (D == 3)
            ? (Z * v.scale - v.center[2])
            : Interval{v.center[2], v.center[2]};
    }
}

template <typename A, typename B>
__device__ inline Interval intervalOp(uint8_t op, A lhs, B rhs, uint8_t& choice)
{
    using namespace libfive::Opcode;
    switch (op) {
        case OP_SQUARE: return square(lhs);
        case OP_SQRT: return sqrt(lhs);
        case OP_NEG: return -lhs;
        // Skipping transcendental functions for now

        case OP_ADD: return lhs + rhs;
        case OP_MUL: return lhs * rhs;
        case OP_DIV: return lhs / rhs;
        case OP_MIN: if (upper(lhs) < lower(rhs)) {
                         choice = 1;
                         return lhs;
                     } else if (upper(rhs) < lower(lhs)) {
                         choice = 2;
                         return rhs;
                     } else {
                         return min(lhs, rhs);
                     }
        case OP_MAX: if (lower(lhs) > upper(rhs)) {
                         choice = 1;
                         return lhs;
                     } else if (lower(rhs) > upper(lhs)) {
                         choice = 2;
                         return rhs;
                     } else {
                         return max(lhs, rhs);
                     }
        case OP_SUB: return lhs - rhs;

        // Skipping various hard functions here
        default: break;
    }
    return {0.0f, 0.0f};
}

template <typename A, typename B>
__device__ inline Deriv derivOp(uint8_t op, A lhs, B rhs)
{
    using namespace libfive::Opcode;
    switch (op) {
        case OP_SQUARE: return lhs * lhs;
        case OP_SQRT: return sqrt(lhs);
        case OP_NEG: return -lhs;
        // Skipping transcendental functions for now

        case OP_ADD: return lhs + rhs;
        case OP_MUL: return lhs * rhs;
        case OP_DIV: return lhs / rhs;
        case OP_MIN: return min(lhs, rhs);
        case OP_MAX: return max(lhs, rhs);
        case OP_SUB: return lhs - rhs;

        // Skipping various hard functions here
        default: break;
    }
    return {0.0f, 0.0f, 0.0f, 0.0f};
}

////////////////////////////////////////////////////////////////////////////////

template <unsigned TILE_SIZE_PX, unsigned DIMENSION>
TileRenderer<TILE_SIZE_PX, DIMENSION>::TileRenderer(
        const Tape& tape, Subtapes& subtapes, Image& image)
    : tape(tape), subtapes(subtapes), tiles(image.size_px)
{
    // Nothing to do here
}

template <unsigned TILE_SIZE_PX, unsigned DIMENSION>
__device__
TileResult TileRenderer<TILE_SIZE_PX, DIMENSION>::check(
        const uint32_t tile, const View& v)
{
    Interval regs[128];
    storeAxes(tile, v, tiles, tape, regs);

    // Unpack a 1D offset into the data arrays
    uint32_t choices[256];
    memset(choices, 0, sizeof(choices));
    uint32_t choice_index = 0;

    const Clause* __restrict__ clause_ptr = &tape[0];
    const float* __restrict__ constant_ptr = &tape.constant(0);
    const auto num_clauses = tape.num_clauses;

    for (uint32_t i=0; i < num_clauses; ++i) {
        using namespace libfive::Opcode;

        const Clause c = clause_ptr[i];
        Interval out;
        uint8_t choice = 0;
        switch (c.banks) {
            case 0: // Interval op Interval
                out = intervalOp<Interval, Interval>(c.opcode,
                        regs[c.lhs],
                        regs[c.rhs],
                        choice);
                break;
            case 1: // Constant op Interval
                out = intervalOp<float, Interval>(c.opcode,
                        constant_ptr[c.lhs],
                        regs[c.rhs],
                        choice);
                break;
            case 2: // Interval op Constant
                out = intervalOp<Interval, float>(c.opcode,
                        regs[c.lhs],
                        constant_ptr[c.rhs],
                        choice);
                break;
            case 3: // Constant op Constant
                out = intervalOp<float, float>(c.opcode,
                        constant_ptr[c.lhs],
                        constant_ptr[c.rhs],
                        choice);
                break;
        }

        if (c.opcode == OP_MIN || c.opcode == OP_MAX) {
            choices[choice_index / 16] |= (choice << ((choice_index % 16) * 2));
            choice_index++;
        }

        regs[c.out] = out;
    }

    const Clause c = clause_ptr[num_clauses - 1];
    const Interval result = regs[c.out];

    // If this tile is unambiguously filled, then mark it at the end
    // of the tiles list
    if (result.upper() < 0.0f) {
        return TILE_FILLED;
    }

    // If the tile is empty, then return immediately
    else if (result.lower() > 0.0f)
    {
        return TILE_EMPTY;
    }

    ////////////////////////////////////////////////////////////////////////////
    // Now, we build a tape for this tile (if it's active).  If it isn't active,
    // then we use the thread to help copy stuff to shared memory, but don't
    // write any tape data out.

    // Pick a subset of the active array to use for this block
    uint8_t* __restrict__ active = reinterpret_cast<uint8_t*>(regs);
    memset(active, 0, tape.num_regs);

    // Mark the root of the tree as true
    active[tape[num_clauses - 1].out] = true;

    uint32_t subtape_index = 0;
    uint32_t s = LIBFIVE_CUDA_SUBTAPE_CHUNK_SIZE;

    // Claim a subtape to populate
    subtape_index = subtapes.claim();

    // Since we're reversing the tape, this is going to be the
    // end of the linked list (i.e. next = 0)
    subtapes.next[subtape_index] = 0;

    // Walk from the root of the tape downwards
    Clause* __restrict__ out = subtapes.data[subtape_index];

    bool terminal = true;
    for (uint32_t i=0; i < num_clauses; i++) {
        using namespace libfive::Opcode;
        Clause c = clause_ptr[num_clauses - i - 1];

        uint8_t choice = 0;
        if (c.opcode == OP_MIN || c.opcode == OP_MAX) {
            --choice_index;
            choice = (choices[choice_index / 16] >> ((choice_index % 16) * 2)) & 3;
        }

        if (active[c.out]) {
            active[c.out] = false;
            if (c.opcode == OP_MIN || c.opcode == OP_MAX) {
                if (choice == 1) {
                    if (!(c.banks & 1)) {
                        active[c.lhs] = true;
                        if (c.lhs == c.out) {
                            continue;
                        }
                        c.rhs = c.lhs;
                        c.banks = 0;
                    } else {
                        c.rhs = c.lhs;
                        c.banks = 3;
                    }
                } else if (choice == 2) {
                    if (!(c.banks & 2)) {
                        active[c.rhs] = true;
                        if (c.rhs == c.out) {
                            continue;
                        }
                        c.lhs = c.rhs;
                        c.banks = 0;
                    } else {
                        c.lhs = c.rhs;
                        c.banks = 3;
                    }
                } else if (choice == 0) {
                    terminal = false;
                    active[c.lhs] |= !(c.banks & 1);
                    active[c.rhs] |= !(c.banks & 2);
                } else {
                    assert(false);
                }
            } else {
                active[c.lhs] |= !(c.banks & 1);
                active[c.rhs] |= (c.opcode >= OP_ADD && !(c.banks & 2));
            }

            // Allocate a new subtape and begin writing to it
            if (s == 0) {
                auto next_subtape_index = subtapes.claim();
                subtapes.start[subtape_index] = 0;
                subtapes.next[next_subtape_index] = subtape_index;
                subtapes.prev[subtape_index] = next_subtape_index;

                subtape_index = next_subtape_index;
                s = LIBFIVE_CUDA_SUBTAPE_CHUNK_SIZE;
                out = subtapes.data[subtape_index];
            }
            out[--s] = c;
        }
    }

    // The last subtape may not be completely filled
    subtapes.start[subtape_index] = s;
    subtapes.prev[subtape_index] = 0;
    tiles.setHead(tile, subtape_index, terminal);

    return TILE_AMBIGUOUS;
}

template <unsigned TILE_SIZE_PX, unsigned DIMENSION>
__global__ void TileRenderer_check(
        TileRenderer<TILE_SIZE_PX, DIMENSION>* r,
        Queue* __restrict__ active_tiles,
        Filled<TILE_SIZE_PX>* __restrict__ filled_tiles,
        const uint32_t offset, View v)
{
    // This should be a 1D kernel
    assert(blockDim.y == 1);
    assert(blockDim.z == 1);
    assert(gridDim.y == 1);
    assert(gridDim.z == 1);

    const uint32_t tile = threadIdx.x + blockIdx.x * blockDim.x + offset;
    if (tile < r->tiles.total &&
        !filled_tiles->isMasked(tile))
    {
        switch (r->check(tile, v)) {
            case TILE_FILLED:       filled_tiles->insert(tile); break;
            case TILE_AMBIGUOUS:    active_tiles->insert(tile); break;
            case TILE_EMPTY:        break;
        }
    }
}

////////////////////////////////////////////////////////////////////////////////

template <unsigned TILE_SIZE_PX, unsigned SUBTILE_SIZE_PX, unsigned DIMENSION>
SubtileRenderer<TILE_SIZE_PX, SUBTILE_SIZE_PX, DIMENSION>::SubtileRenderer(
        const Tape& tape, Subtapes& subtapes, Image& image,
        Tiles<TILE_SIZE_PX, DIMENSION>& prev)
    : tape(tape), subtapes(subtapes), tiles(prev),
      subtiles(image.size_px)
{
    // Nothing to do here
}

template <unsigned TILE_SIZE_PX, unsigned SUBTILE_SIZE_PX, unsigned DIMENSION>
__device__
TileResult SubtileRenderer<TILE_SIZE_PX, SUBTILE_SIZE_PX, DIMENSION>::check(
        const uint32_t subtile, const uint32_t tile, const View& v)
{
    Interval regs[128];
    storeAxes(subtile, v, subtiles, tape, regs);

    uint32_t choices[256];
    memset(choices, 0, sizeof(choices));
    uint32_t choice_index = 0;

    // Run actual evaluation
    uint32_t subtape_index = tiles.head(tile);
    uint32_t s = subtapes.start[subtape_index];
    const Clause* __restrict__ tape = subtapes.data[subtape_index];
    const float* __restrict__ constant_ptr = &this->tape.constant(0);

    Interval result;
    while (true) {
        using namespace libfive::Opcode;

        if (s == LIBFIVE_CUDA_SUBTAPE_CHUNK_SIZE) {
            uint32_t next = subtapes.next[subtape_index];
            if (next) {
                subtape_index = next;
                s = subtapes.start[subtape_index];
                tape = subtapes.data[subtape_index];
            } else {
                result = regs[tape[s - 1].out];
                break;
            }
        }
        const Clause c = tape[s++];

        Interval out;
        uint8_t choice = 0;
        switch (c.banks) {
            case 0: // Interval op Interval
                out = intervalOp<Interval, Interval>(c.opcode,
                        regs[c.lhs],
                        regs[c.rhs], choice);
                break;
            case 1: // Constant op Interval
                out = intervalOp<float, Interval>(c.opcode,
                        constant_ptr[c.lhs],
                        regs[c.rhs], choice);
                break;
            case 2: // Interval op Constant
                out = intervalOp<Interval, float>(c.opcode,
                         regs[c.lhs],
                         constant_ptr[c.rhs], choice);
                break;
            case 3: // Constant op Constant
                out = intervalOp<float, float>(c.opcode,
                        constant_ptr[c.lhs],
                        constant_ptr[c.rhs], choice);
                break;
        }
        if (c.opcode == OP_MIN || c.opcode == OP_MAX) {
            choices[choice_index / 16] |= (choice << ((choice_index % 16) * 2));
            choice_index++;
        }

        regs[c.out] = out;
    }

    ////////////////////////////////////////////////////////////////////////////
    // If this tile is unambiguously filled, then mark it at the end
    // of the tiles list
    if (result.upper() < 0.0f) {
        return TILE_FILLED;
    }

    // If the tile is empty, then return right away
    else if (result.lower() > 0.0f)
    {
        return TILE_EMPTY;
    }

    ////////////////////////////////////////////////////////////////////////////

    // Re-use the previous tape and return immediately if the previous
    // tape was terminal (i.e. having no min/max clauses to specialize)
    bool terminal = tiles.terminal(tile);
    if (terminal) {
        subtiles.setHead(subtile, tiles.head(tile), true);
        return TILE_AMBIGUOUS;
    }

    // Pick a subset of the active array to use for this block
    uint8_t* __restrict__ active = reinterpret_cast<uint8_t*>(regs);
    memset(active, 0, this->tape.num_regs);

    // At this point, subtape_index is pointing to the last chunk, so we'll
    // use the prev pointers to walk backwards (where "backwards" means
    // from the root of the tree to its leaves).
    uint32_t in_subtape_index = subtape_index;
    uint32_t in_s = LIBFIVE_CUDA_SUBTAPE_CHUNK_SIZE;
    uint32_t in_s_end = subtapes.start[in_subtape_index];
    const Clause* __restrict__ in_tape = subtapes.data[in_subtape_index];

    // Mark the head of the tape as active
    active[in_tape[in_s - 1].out] = true;

    // Claim a subtape to populate
    uint32_t out_subtape_index = subtapes.claim();
    assert(out_subtape_index < LIBFIVE_CUDA_NUM_SUBTAPES);
    uint32_t out_s = LIBFIVE_CUDA_SUBTAPE_CHUNK_SIZE;
    Clause* __restrict__ out_tape = subtapes.data[out_subtape_index];

    // Since we're reversing the tape, this is going to be the
    // end of the linked list (i.e. next = 0)
    subtapes.next[out_subtape_index] = 0;

    terminal = true;
    while (true) {
        using namespace libfive::Opcode;

        // If we've reached the end of an input tape chunk, then
        // either move on to the next one or escape the loop
        if (in_s == in_s_end) {
            const uint32_t prev = subtapes.prev[in_subtape_index];
            if (prev) {
                in_subtape_index = prev;
                in_s = LIBFIVE_CUDA_SUBTAPE_CHUNK_SIZE;
                in_s_end = subtapes.start[in_subtape_index];
                in_tape = subtapes.data[in_subtape_index];
            } else {
                break;
            }
        }
        Clause c = in_tape[--in_s];

        uint8_t choice = 0;
        if (c.opcode == OP_MIN || c.opcode == OP_MAX) {
            --choice_index;
            choice = (choices[choice_index / 16] >> ((choice_index % 16) * 2)) & 3;
        }

        if (active[c.out]) {
            active[c.out] = false;
            if (c.opcode == OP_MIN || c.opcode == OP_MAX) {
                if (choice == 1) {
                    if (!(c.banks & 1)) {
                        active[c.lhs] = true;
                        if (c.lhs == c.out) {
                            continue;
                        }
                        c.rhs = c.lhs;
                        c.banks = 0;
                    } else {
                        c.rhs = c.lhs;
                        c.banks = 3;
                    }
                } else if (choice == 2) {
                    if (!(c.banks & 2)) {
                        active[c.rhs] = true;
                        if (c.rhs == c.out) {
                            continue;
                        }
                        c.lhs = c.rhs;
                        c.banks = 0;
                    } else {
                        c.lhs = c.rhs;
                        c.banks = 3;
                    }
                } else if (choice == 0) {
                    active[c.lhs] |= (!(c.banks & 1));
                    active[c.rhs] |= (!(c.banks & 2));
                } else {
                    assert(false);
                }
            } else {
                terminal = false;
                active[c.lhs] |= (!(c.banks & 1));
                active[c.rhs] |= (c.opcode >= OP_ADD && !(c.banks & 2));
            }

            // If we've reached the end of the output tape, then
            // allocate a new one and keep going
            if (out_s == 0) {
                const auto next = subtapes.claim();
                subtapes.start[out_subtape_index] = 0;
                subtapes.next[next] = out_subtape_index;
                subtapes.prev[out_subtape_index] = next;

                out_subtape_index = next;
                out_s = LIBFIVE_CUDA_SUBTAPE_CHUNK_SIZE;
                out_tape = subtapes.data[out_subtape_index];
            }

            out_tape[--out_s] = c;
        }
    }

    // The last subtape may not be completely filled, so write its size here
    subtapes.start[out_subtape_index] = out_s;
    subtapes.prev[out_subtape_index] = 0;
    subtiles.setHead(subtile, out_subtape_index, terminal);

    return TILE_AMBIGUOUS;
}

template <unsigned TILE_SIZE_PX, unsigned SUBTILE_SIZE_PX, unsigned DIMENSION>
__global__
void SubtileRenderer_check(
        SubtileRenderer<TILE_SIZE_PX, SUBTILE_SIZE_PX, DIMENSION>* r,

        const Queue* __restrict__ active_tiles,
        Queue* __restrict__ active_subtiles,

        const Filled<TILE_SIZE_PX>* __restrict__ filled_tiles,
        Filled<SUBTILE_SIZE_PX>* __restrict__ filled_subtiles,

        const uint32_t offset, View v)
{
    assert(blockDim.x % r->subtilesPerTile() == 0);
    assert(blockDim.y == 1);
    assert(blockDim.z == 1);
    assert(gridDim.y == 1);
    assert(gridDim.z == 1);

    // Pick an active tile from the list.  Each block executes multiple tiles!
    const uint32_t stride = blockDim.x / r->subtilesPerTile();
    const uint32_t sub = threadIdx.x / r->subtilesPerTile();
    const uint32_t i = offset + blockIdx.x * stride + sub;

    if (i < active_tiles->count) {
        // Pick out the next active tile
        // (this will be the same for every thread in a block)
        const uint32_t tile = (*active_tiles)[i];

        // Convert from tile position to pixels
        const uint3 p = r->tiles.lowerCornerVoxel(tile);

        // Calculate the subtile's offset within the tile
        const uint32_t q = threadIdx.x % r->subtilesPerTile();
        const uint3 d = make_uint3(
             q % r->subtilesPerTileSide(),
             (q / r->subtilesPerTileSide()) % r->subtilesPerTileSide(),
             (q / r->subtilesPerTileSide()) / r->subtilesPerTileSide());

        const uint32_t tx = p.x / SUBTILE_SIZE_PX + d.x;
        const uint32_t ty = p.y / SUBTILE_SIZE_PX + d.y;
        const uint32_t tz = p.z / SUBTILE_SIZE_PX + d.z;
        if (DIMENSION == 2) {
            assert(tz == 0);
        }

        // Finally, unconvert back into a single index
        const uint32_t subtile = tx + ty * r->subtiles.per_side
             + tz * r->subtiles.per_side * r->subtiles.per_side;

        if (!filled_tiles->isMasked(tile) &&
            !filled_subtiles->isMasked(subtile))
        {
            switch (r->check(subtile, tile, v)) {
                case TILE_FILLED:       filled_subtiles->insert(subtile); break;
                case TILE_AMBIGUOUS:    active_subtiles->insert(subtile); break;
                case TILE_EMPTY:        break;
            }
        }
    }
}

////////////////////////////////////////////////////////////////////////////////

template <unsigned SUBTILE_SIZE_PX, unsigned DIMENSION>
PixelRenderer<SUBTILE_SIZE_PX, DIMENSION>::PixelRenderer(
        const Tape& tape, const Subtapes& subtapes, Image& image,
        const Tiles<SUBTILE_SIZE_PX, DIMENSION>& prev)
    : tape(tape), subtapes(subtapes), image(image), subtiles(prev)
{
    // Nothing to do here
}

template <unsigned SUBTILE_SIZE_PX, unsigned DIMENSION>
__device__ void PixelRenderer<SUBTILE_SIZE_PX, DIMENSION>::draw(
        const uint32_t subtile, const View& v)
{
    const uint32_t pixel = threadIdx.x % pixelsPerSubtile();
    const uint3 d = make_uint3(
            pixel % SUBTILE_SIZE_PX,
            (pixel / SUBTILE_SIZE_PX) % SUBTILE_SIZE_PX,
            (pixel / SUBTILE_SIZE_PX) / SUBTILE_SIZE_PX);

    float regs[128];

    // Convert from tile position to pixels
    const uint3 p = subtiles.lowerCornerVoxel(subtile);

    // Skip this pixel if it's already below the image
    if (DIMENSION == 3 && image(p.x + d.x, p.y + d.y) >= p.z + d.z) {
        return;
    }

    {   // Prepopulate axis values
        float3 f = image.voxelPos(make_uint3(
                    p.x + d.x, p.y + d.y, p.z + d.z));
        if (tape.axes.reg[0] != UINT16_MAX) {
            regs[tape.axes.reg[0]] = f.x * v.scale - v.center[0];
        }
        if (tape.axes.reg[1] != UINT16_MAX) {
            regs[tape.axes.reg[1]] = f.y * v.scale - v.center[1];
        }
        if (tape.axes.reg[2] != UINT16_MAX) {
            regs[tape.axes.reg[2]] = (DIMENSION == 3)
                ? (f.z * v.scale)
                : v.center[2];
        }
    }

    uint32_t subtape_index = subtiles.head(subtile);
    uint32_t s = subtapes.start[subtape_index];
    const float* __restrict__ constant_ptr = &tape.constant(0);
    const Clause* __restrict__ tape = subtapes.data[subtape_index];

    while (true) {
        using namespace libfive::Opcode;

        // Move to the next subtape if this one is finished
        if (s == LIBFIVE_CUDA_SUBTAPE_CHUNK_SIZE) {
            const uint32_t next = subtapes.next[subtape_index];
            if (next) {
                subtape_index = next;
                s = subtapes.start[subtape_index];
                tape = subtapes.data[subtape_index];
            } else {
                if (regs[tape[s - 1].out] < 0.0f) {
                    if (DIMENSION == 2) {
                        image(p.x + d.x, p.y + d.y) = 255;
                    } else {
                        atomicMax(&image(p.x + d.x, p.y + d.y), p.z + d.z);
                    }
                }
                return;
            }
        }
        const Clause c = tape[s++];

        // All clauses must have at least one argument, since constants
        // and VAR_X/Y/Z are handled separately.
        float lhs;
        if (c.banks & 1) {
            lhs = constant_ptr[c.lhs];
        } else {
            lhs = regs[c.lhs];
        }

        float rhs;
        if (c.banks & 2) {
            rhs = constant_ptr[c.rhs];
        } else if (c.opcode >= OP_ADD) {
            rhs = regs[c.rhs];
        }

        float out;
        switch (c.opcode) {
            case OP_SQUARE: out = lhs * lhs; break;
            case OP_SQRT: out = sqrtf(lhs); break;
            case OP_NEG: out = -lhs; break;
            // Skipping transcendental functions for now

            case OP_ADD: out = lhs + rhs; break;
            case OP_MUL: out = lhs * rhs; break;
            case OP_DIV: out = lhs / rhs; break;
            case OP_MIN: out = fminf(lhs, rhs); break;
            case OP_MAX: out = fmaxf(lhs, rhs); break;
            case OP_SUB: out = lhs - rhs; break;

            // Skipping various hard functions here
            default: break;
        }
        regs[c.out] = out;
    }
}

template <unsigned SUBTILE_SIZE_PX, unsigned DIMENSION>
__global__ void PixelRenderer_draw(
        PixelRenderer<SUBTILE_SIZE_PX, DIMENSION>* r,
        const Queue* __restrict__ active,
        const Filled<SUBTILE_SIZE_PX>* __restrict__ filled,
        const uint32_t offset, View v)
{
    // We assume one thread per pixel in a set of tiles
    assert(blockDim.x % SUBTILE_SIZE_PX == 0);
    assert(blockDim.y == 1);
    assert(blockDim.z == 1);
    assert(gridDim.y == 1);
    assert(gridDim.z == 1);

    // Pick an active tile from the list.  Each block executes multiple tiles!
    const uint32_t stride = blockDim.x / r->pixelsPerSubtile();
    const uint32_t sub = threadIdx.x / r->pixelsPerSubtile();
    const uint32_t i = offset + blockIdx.x * stride + sub;

    if (i < active->count) {
        const uint32_t subtile = (*active)[i];
        if (!filled->isMasked(subtile)) {
            r->draw(subtile, v);
        }
    }
}

////////////////////////////////////////////////////////////////////////////////

NormalRenderer::NormalRenderer(const Tape& tape,
                               const Subtapes& subtapes,
                               Image& norm)
    : tape(tape), subtapes(subtapes), norm(norm)
{
    // Nothing to do here
}

__device__ uint32_t NormalRenderer::draw(const float3 f,
                                         uint32_t subtape_index,
                                         const View& v)
{
    Deriv regs[128];

    {   // Prepopulate axis values
        if (tape.axes.reg[0] != UINT16_MAX) {
            const float x = f.x * v.scale - v.center[0];
            regs[tape.axes.reg[0]] = Deriv(x, 1.0f, 0.0f, 0.0f);
        }
        if (tape.axes.reg[1] != UINT16_MAX) {
            const float y = f.y * v.scale - v.center[1];
            regs[tape.axes.reg[1]] = Deriv(y, 0.0f, 1.0f, 0.0f);
        }
        if (tape.axes.reg[2] != UINT16_MAX) {
            const float z = (f.z * v.scale);
            regs[tape.axes.reg[2]] = Deriv(z, 0.0f, 0.0f, 1.0f);
        }
    }

    uint32_t s = subtapes.start[subtape_index];
    const float* __restrict__ constant_ptr = &tape.constant(0);
    const Clause* __restrict__ tape = subtapes.data[subtape_index];

    while (true) {
        using namespace libfive::Opcode;

        // Move to the next subtape if this one is finished
        if (s == LIBFIVE_CUDA_SUBTAPE_CHUNK_SIZE) {
            const uint32_t next = subtapes.next[subtape_index];
            if (next) {
                subtape_index = next;
                s = subtapes.start[subtape_index];
                tape = subtapes.data[subtape_index];
            } else {
                break;
            }
        }
        const Clause c = tape[s++];

        Deriv out;
        switch (c.banks) {
            case 0: // Deriv op Deriv
                out = derivOp<Deriv, Deriv>(c.opcode,
                        regs[c.lhs],
                        regs[c.rhs]);
                break;
            case 1: // Constant op Deriv
                out = derivOp<float, Deriv>(c.opcode,
                        constant_ptr[c.lhs],
                        regs[c.rhs]);
                break;
            case 2: // Deriv op Constant
                out = derivOp<Deriv, float>(c.opcode,
                        regs[c.lhs],
                        constant_ptr[c.rhs]);
                break;
            case 3: // Constant op Constant
                out = derivOp<float, float>(c.opcode,
                        constant_ptr[c.lhs],
                        constant_ptr[c.rhs]);
                break;
        }
        regs[c.out] = out;
    }

    const Deriv result = regs[tape[s - 1].out];
    float norm = sqrtf(powf(result.dx(), 2) +
                       powf(result.dy(), 2) +
                       powf(result.dz(), 2));
    uint8_t dx = (result.dx() / norm) * 127 + 128;
    uint8_t dy = (result.dy() / norm) * 127 + 128;
    uint8_t dz = (result.dz() / norm) * 127 + 128;
    return (0xFF << 24) | (dz << 16) | (dy << 8) | dx;
}

__global__ void Renderable3D_drawNormals(
        Renderable3D* r, const uint32_t offset, View v)
{
    assert(blockDim.y == 1);
    assert(blockDim.z == 1);
    assert(gridDim.y == 1);
    assert(gridDim.z == 1);

    const uint32_t pixel = threadIdx.x % (16 * 16);

    const uint32_t i = offset + (threadIdx.x + blockIdx.x * blockDim.x) /
                                (16 * 16);
    const uint32_t px = (i % (r->norm.size_px / 16)) * 16 +
                        (pixel % 16);
    const uint32_t py = (i / (r->norm.size_px / 16)) * 16 +
                        (pixel / 16);
    if (px < r->norm.size_px && py < r->norm.size_px) {
        const uint32_t pz = min(r->image(px, py) + 1, r->image.size_px - 1);
        if (pz) {
            const uint3 p = make_uint3(px, py, pz);
            const float3 f = r->norm.voxelPos(p);
            const uint32_t h = r->subtapeHeadAt(p);
            if (h) {
                const uint32_t n = r->drawNormals(f, h, v);
                r->norm(p.x, p.y) = n;
            }
        }
    }
}

__device__
uint32_t Renderable3D::drawNormals(const float3 f,
                                   const uint32_t subtape_index,
                                   const View& v)
{
    return normal_renderer.draw(f, subtape_index, v);
}

__device__
uint32_t Renderable3D::subtapeHeadAt(const uint3 v) const
{
    if (auto h = pixel_renderer.subtiles.headAtVoxel(v)) {
        return h;
    } else if (auto h = subtile_renderer.subtiles.headAtVoxel(v)) {
        return h;
    } else if (auto h = tile_renderer.tiles.headAtVoxel(v)) {
        return h;
    } else {
        return 0;
    }
}

__device__
void Renderable3D::copyDepthToImage()
{
    unsigned x = threadIdx.x + blockIdx.x * blockDim.x;
    unsigned y = threadIdx.y + blockIdx.y * blockDim.y;

    const unsigned size = image.size_px;
    if (x < size && y < size) {
        const uint32_t c = image(x, y);
        const uint32_t t = filled_tiles.at(x, y);
        const uint32_t s = filled_subtiles.at(x, y);
        const uint32_t u = filled_microtiles.at(x, y);

        image(x, y) = max(max(c, t), max(s, u));
    }
}

__device__
void Renderable2D::copyDepthToImage()
{
    unsigned x = threadIdx.x + blockIdx.x * blockDim.x;
    unsigned y = threadIdx.y + blockIdx.y * blockDim.y;

    const unsigned size = image.size_px;
    if (x < size && y < size) {
        const uint32_t c = image(x, y);
        const uint32_t t = filled_tiles.at(x, y);
        const uint32_t s = filled_subtiles.at(x, y);

        image(x, y) = (c || t || s) ? (image.size_px - 1) : 0;
    }
}

__global__
void Renderable3D_copyDepthToImage(Renderable3D* r)
{
    r->copyDepthToImage();
}

__global__
void Renderable2D_copyDepthToImage(Renderable2D* r)
{
    r->copyDepthToImage();
}

__device__
void Renderable3D::copyDepthToSurface(cudaSurfaceObject_t surf,
                                      uint32_t texture_size,
                                      bool append)
{
    unsigned x = threadIdx.x + blockIdx.x * blockDim.x;
    unsigned y = threadIdx.y + blockIdx.y * blockDim.y;

    if (x < texture_size && y < texture_size) {
        uint32_t px = x * image.size_px / texture_size;
        uint32_t py = y * image.size_px / texture_size;
        const auto h = image(px, image.size_px - py - 1);
        if (h) {
            surf2Dwrite(0x00FFFFFF | (((h * 255) / image.size_px) << 24),
                        surf, x*4, y);
        } else if (!append) {
            surf2Dwrite(0, surf, x*4, y);
        }
    }
}

__device__
void Renderable3D::copyNormalToSurface(cudaSurfaceObject_t surf,
                                       uint32_t texture_size,
                                       bool append)
{
    unsigned x = threadIdx.x + blockIdx.x * blockDim.x;
    unsigned y = threadIdx.y + blockIdx.y * blockDim.y;

    if (x < texture_size && y < texture_size) {
        uint32_t px = x * image.size_px / texture_size;
        uint32_t py = y * image.size_px / texture_size;
        const auto h = image(px, image.size_px - py - 1);
        if (h) {
            surf2Dwrite(norm(px, image.size_px - py - 1), surf, x*4, y);
        } else if (!append) {
            surf2Dwrite(0, surf, x*4, y);
        }
    }
}

__device__
void Renderable2D::copyToSurface(cudaSurfaceObject_t surf,
                                 uint32_t texture_size, bool append)
{
    unsigned x = threadIdx.x + blockIdx.x * blockDim.x;
    unsigned y = threadIdx.y + blockIdx.y * blockDim.y;

    if (x < texture_size && y < texture_size) {
        const uint32_t px = x * image.size_px / texture_size;
        const uint32_t py = y * image.size_px / texture_size;
        const auto h = image(px, image.size_px - py - 1);
        if (h) {
            surf2Dwrite(0xFFFFFFFF, surf, x*4, y);
        } else if (!append) {
            surf2Dwrite(0, surf, x*4, y);
        }
    }
}

__global__
void Renderable3D_copyDepthToSurface(Renderable3D* r, cudaSurfaceObject_t surf,
                                     uint32_t texture_size, bool append)
{
    r->copyDepthToSurface(surf, texture_size, append);
}

__global__
void Renderable3D_copyNormalToSurface(Renderable3D* r,
                                      cudaSurfaceObject_t surf,
                                      uint32_t texture_size, bool append)
{
    r->copyNormalToSurface(surf, texture_size, append);
}

__global__
void Renderable2D_copyToSurface(Renderable2D* r, cudaSurfaceObject_t surf,
                                uint32_t texture_size, bool append)
{
    r->copyToSurface(surf, texture_size, append);
}

////////////////////////////////////////////////////////////////////////////////

void Renderable::Deleter::operator()(Renderable* r)
{
    r->~Renderable();
    CUDA_CHECK(cudaFree(r));
}

Renderable::~Renderable()
{
    for (unsigned i=0; i < LIBFIVE_CUDA_NUM_STREAMS; ++i) {
        CUDA_CHECK(cudaStreamDestroy(streams[i]));
    }
}

Renderable::Handle Renderable::build(libfive::Tree tree, uint32_t image_size_px, uint8_t dimension)
{
    Renderable* out;
    if (dimension == 2) {
        out = CUDA_MALLOC(Renderable2D, 1);
        new (out) Renderable2D(tree, image_size_px);
    } else if (dimension == 3) {
        out = CUDA_MALLOC(Renderable3D, 1);
        new (out) Renderable3D(tree, image_size_px);
    }
    cudaDeviceSynchronize();
    return Handle(out);
}

Renderable::Renderable(libfive::Tree tree, uint32_t image_size_px)
    : image(image_size_px),
      tape(std::move(Tape::build(tree)))
{
    for (unsigned i=0; i < LIBFIVE_CUDA_NUM_STREAMS; ++i) {
        CUDA_CHECK(cudaStreamCreate(&streams[i]));
    }
}

Renderable3D::Renderable3D(libfive::Tree tree, uint32_t image_size_px)
    : Renderable(tree, image_size_px),
      norm(image_size_px),

      filled_tiles(image_size_px),
      filled_subtiles(image_size_px),
      filled_microtiles(image_size_px),

      tile_renderer(tape, subtapes, image),
      subtile_renderer(tape, subtapes, image, tile_renderer.tiles),
      microtile_renderer(tape, subtapes, image, subtile_renderer.subtiles),

      pixel_renderer(tape, subtapes, image, microtile_renderer.subtiles),
      normal_renderer(tape, subtapes, norm)
{
    // Nothing to do here
}

Renderable2D::Renderable2D(libfive::Tree tree, uint32_t image_size_px)
    : Renderable(tree, image_size_px),

      filled_tiles(image_size_px),
      filled_subtiles(image_size_px),

      tile_renderer(tape, subtapes, image),
      subtile_renderer(tape, subtapes, image, tile_renderer.tiles),

      pixel_renderer(tape, subtapes, image, subtile_renderer.subtiles)
{
    // Nothing to do here
}

void Renderable3D::run(const View& view)
{
    // Reset everything in preparation for a render
    subtapes.reset();
    image.reset();
    norm.reset();
    tile_renderer.tiles.reset();
    subtile_renderer.subtiles.reset();
    microtile_renderer.subtiles.reset();

    filled_tiles.reset();
    filled_subtiles.reset();
    filled_microtiles.reset();

    // Record this local variable because otherwise it looks up memory
    // that has been loaned to the GPU and not synchronized.
    auto tile_renderer = &this->tile_renderer;
    auto subtile_renderer = &this->subtile_renderer;
    auto microtile_renderer = &this->microtile_renderer;
    auto pixel_renderer = &this->pixel_renderer;

    cudaStream_t streams[LIBFIVE_CUDA_NUM_STREAMS];
    for (unsigned i=0; i < LIBFIVE_CUDA_NUM_STREAMS; ++i) {
        streams[i] = this->streams[i];
    }

    {   // Do per-tile evaluation to get filled / ambiguous tiles
        const uint32_t stride = LIBFIVE_CUDA_TILE_THREADS *
                                LIBFIVE_CUDA_TILE_BLOCKS;
        const uint32_t total_tiles = tile_renderer->tiles.total;
        auto queue_out = &this->queue_ping;
        queue_out->resizeToFit(total_tiles);
        auto filled_out = &this->filled_tiles;
        for (unsigned i=0; i < total_tiles; i += stride) {
            TileRenderer_check<<<
                LIBFIVE_CUDA_TILE_BLOCKS,
                LIBFIVE_CUDA_TILE_THREADS,
                0,
                streams[(i / stride) % LIBFIVE_CUDA_NUM_STREAMS]>>>(
                    tile_renderer, queue_out, filled_out, i, view);
        }
    }
    CUDA_CHECK(cudaDeviceSynchronize());

    {   // Refine ambiguous tiles from their subtapes
        const uint32_t stride = LIBFIVE_CUDA_SUBTILE_BLOCKS *
                                LIBFIVE_CUDA_REFINE_TILES;
        auto queue_in  = &this->queue_ping;
        auto queue_out = &this->queue_pong;
        auto filled_in  = &this->filled_tiles;
        auto filled_out = &this->filled_subtiles;
        const uint32_t active = queue_in->count;
        queue_out->resizeToFit(active * subtile_renderer->subtilesPerTile());
        for (unsigned i=0; i < active; i += stride) {
            SubtileRenderer_check<<<
                LIBFIVE_CUDA_SUBTILE_BLOCKS,
                subtile_renderer->subtilesPerTile() *
                    LIBFIVE_CUDA_REFINE_TILES,
                0,
                streams[(i / stride) % LIBFIVE_CUDA_NUM_STREAMS]>>>(
                    subtile_renderer,
                    queue_in, queue_out,
                    filled_in, filled_out,
                    i, view);
            CUDA_CHECK(cudaGetLastError());
        }
    }
    CUDA_CHECK(cudaDeviceSynchronize());

    {   // Refine ambiguous tiles from their subtapes
        const uint32_t stride = LIBFIVE_CUDA_SUBTILE_BLOCKS *
                                LIBFIVE_CUDA_REFINE_TILES;
        auto queue_in  = &this->queue_pong;
        auto queue_out = &this->queue_ping;
        auto filled_in  = &this->filled_subtiles;
        auto filled_out = &this->filled_microtiles;
        const uint32_t active = queue_in->count;
        queue_out->resizeToFit(active * microtile_renderer->subtilesPerTile());
        for (unsigned i=0; i < active; i += stride) {
            SubtileRenderer_check<<<
                LIBFIVE_CUDA_SUBTILE_BLOCKS,
                microtile_renderer->subtilesPerTile() *
                    LIBFIVE_CUDA_REFINE_TILES,
                0,
                streams[(i / stride) % LIBFIVE_CUDA_NUM_STREAMS]>>>(
                    microtile_renderer,
                    queue_in, queue_out,
                    filled_in, filled_out,
                    i, view);
            CUDA_CHECK(cudaGetLastError());
        }
        CUDA_CHECK(cudaDeviceSynchronize());
    }

    {   // Do pixel-by-pixel rendering for active subtiles
        const uint32_t stride = LIBFIVE_CUDA_RENDER_BLOCKS *
                                LIBFIVE_CUDA_RENDER_SUBTILES;
        auto queue_in  = &this->queue_ping;
        auto filled_in = &this->filled_microtiles;
        const uint32_t active = queue_in->count;
        for (unsigned i=0; i < active; i += stride) {
            PixelRenderer_draw<<<
                LIBFIVE_CUDA_RENDER_BLOCKS,
                pixel_renderer->pixelsPerSubtile() *
                    LIBFIVE_CUDA_RENDER_SUBTILES,
                0,
                streams[(i / stride) % LIBFIVE_CUDA_NUM_STREAMS]>>>(
                    pixel_renderer, queue_in, filled_in, i, view);
            CUDA_CHECK(cudaGetLastError());
        }
    }
    CUDA_CHECK(cudaDeviceSynchronize());

    Renderable3D_copyDepthToImage<<<dim3(256, 256), dim3(16, 16)>>>(this);
    CUDA_CHECK(cudaGetLastError());
    CUDA_CHECK(cudaDeviceSynchronize());

    {   // Do pixel-by-pixel rendering for normals
        const uint32_t active = pow(image.size_px / 16, 2);
        const uint32_t stride = LIBFIVE_CUDA_NORMAL_BLOCKS *
                                LIBFIVE_CUDA_NORMAL_TILES;
        for (unsigned i=0; i < active; i += stride) {
            Renderable3D_drawNormals<<<
                LIBFIVE_CUDA_NORMAL_BLOCKS,
                pow(16, 2) * LIBFIVE_CUDA_NORMAL_TILES,
                0, streams[(i / stride) % LIBFIVE_CUDA_NUM_STREAMS]>>>(
                    this, i, view);
            CUDA_CHECK(cudaGetLastError());
        }
    }
    CUDA_CHECK(cudaDeviceSynchronize());
}

void Renderable2D::run(const View& view)
{
    // Reset everything in preparation for a render
    subtapes.reset();
    image.reset();
    tile_renderer.tiles.reset();
    subtile_renderer.subtiles.reset();

    filled_tiles.reset();
    filled_subtiles.reset();

    // Record this local variable because otherwise it looks up memory
    // that has been loaned to the GPU and not synchronized.
    auto tile_renderer = &this->tile_renderer;
    auto subtile_renderer = &this->subtile_renderer;
    auto pixel_renderer = &this->pixel_renderer;

    cudaStream_t streams[LIBFIVE_CUDA_NUM_STREAMS];
    for (unsigned i=0; i < LIBFIVE_CUDA_NUM_STREAMS; ++i) {
        streams[i] = this->streams[i];
    }

    {   // Do per-tile evaluation to get filled / ambiguous tiles
        const uint32_t stride = LIBFIVE_CUDA_TILE_THREADS *
                                LIBFIVE_CUDA_TILE_BLOCKS;
        const uint32_t total_tiles = tile_renderer->tiles.total;
        auto queue_out = &this->queue_ping;
        queue_out->resizeToFit(total_tiles);
        auto filled_out = &this->filled_tiles;
        for (unsigned i=0; i < total_tiles; i += stride) {
            TileRenderer_check<<<
                LIBFIVE_CUDA_TILE_BLOCKS,
                LIBFIVE_CUDA_TILE_THREADS,
                0,
                streams[(i / stride) % LIBFIVE_CUDA_NUM_STREAMS]>>>(
                    tile_renderer, queue_out, filled_out, i, view);
        }
    }
    CUDA_CHECK(cudaDeviceSynchronize());

    {   // Refine ambiguous tiles from their subtapes
        const uint32_t stride = LIBFIVE_CUDA_SUBTILE_BLOCKS *
                                LIBFIVE_CUDA_REFINE_TILES;
        auto queue_in  = &this->queue_ping;
        auto queue_out = &this->queue_pong;
        auto filled_in  = &this->filled_tiles;
        auto filled_out = &this->filled_subtiles;
        const uint32_t active = queue_in->count;
        queue_out->resizeToFit(active * subtile_renderer->subtilesPerTile());
        for (unsigned i=0; i < active; i += stride) {
            SubtileRenderer_check<<<
                LIBFIVE_CUDA_SUBTILE_BLOCKS,
                subtile_renderer->subtilesPerTile() *
                    LIBFIVE_CUDA_REFINE_TILES,
                0,
                streams[(i / stride) % LIBFIVE_CUDA_NUM_STREAMS]>>>(
                    subtile_renderer,
                    queue_in, queue_out,
                    filled_in, filled_out,
                    i, view);
            CUDA_CHECK(cudaGetLastError());
        }
    }
    CUDA_CHECK(cudaDeviceSynchronize());

    {   // Do pixel-by-pixel rendering for active subtiles
        const uint32_t stride = LIBFIVE_CUDA_RENDER_BLOCKS *
                                LIBFIVE_CUDA_RENDER_SUBTILES;
        auto queue_in  = &this->queue_pong;
        auto filled_in = &this->filled_subtiles;
        const uint32_t active = queue_in->count;
        for (unsigned i=0; i < active; i += stride) {
            PixelRenderer_draw<<<
                LIBFIVE_CUDA_RENDER_BLOCKS,
                pixel_renderer->pixelsPerSubtile() *
                    LIBFIVE_CUDA_RENDER_SUBTILES,
                0,
                streams[(i / stride) % LIBFIVE_CUDA_NUM_STREAMS]>>>(
                    pixel_renderer, queue_in, filled_in, i, view);
            CUDA_CHECK(cudaGetLastError());
        }
    }
    CUDA_CHECK(cudaDeviceSynchronize());

    Renderable2D_copyDepthToImage<<<dim3(256, 256), dim3(16, 16)>>>(this);
    CUDA_CHECK(cudaGetLastError());
    CUDA_CHECK(cudaDeviceSynchronize());
}

cudaGraphicsResource* Renderable::registerTexture(GLuint t)
{
    cudaGraphicsResource* gl_tex;
    CUDA_CHECK(cudaGraphicsGLRegisterImage(&gl_tex, t, GL_TEXTURE_2D,
                                      cudaGraphicsMapFlagsWriteDiscard));
    return gl_tex;
}

void Renderable2D::copyToTexture(cudaGraphicsResource* gl_tex,
                                 uint32_t texture_size,
                                 bool append, bool mode)
{
    (void)mode; // (unused in 2D)

    cudaArray* array;
    CUDA_CHECK(cudaGraphicsMapResources(1, &gl_tex));
    CUDA_CHECK(cudaGraphicsSubResourceGetMappedArray(&array, gl_tex, 0, 0));

    // Specify texture
    struct cudaResourceDesc res_desc;
    memset(&res_desc, 0, sizeof(res_desc));
    res_desc.resType = cudaResourceTypeArray;
    res_desc.res.array.array = array;

    // Surface object??!
    cudaSurfaceObject_t surf = 0;
    CUDA_CHECK(cudaCreateSurfaceObject(&surf, &res_desc));

    CUDA_CHECK(cudaDeviceSynchronize());
    Renderable2D_copyToSurface<<<dim3(256, 256), dim3(16, 16)>>>(
            this, surf, texture_size, append);
    CUDA_CHECK(cudaGetLastError());

    CUDA_CHECK(cudaDeviceSynchronize());
    CUDA_CHECK(cudaDestroySurfaceObject(surf));
    CUDA_CHECK(cudaGraphicsUnmapResources(1, &gl_tex));
}

void Renderable3D::copyToTexture(cudaGraphicsResource* gl_tex,
                                 uint32_t texture_size,
                                 bool append, bool mode)
{
    cudaArray* array;
    CUDA_CHECK(cudaGraphicsMapResources(1, &gl_tex));
    CUDA_CHECK(cudaGraphicsSubResourceGetMappedArray(&array, gl_tex, 0, 0));

    // Specify texture
    struct cudaResourceDesc res_desc;
    memset(&res_desc, 0, sizeof(res_desc));
    res_desc.resType = cudaResourceTypeArray;
    res_desc.res.array.array = array;

    // Surface object??!
    cudaSurfaceObject_t surf = 0;
    CUDA_CHECK(cudaCreateSurfaceObject(&surf, &res_desc));

    CUDA_CHECK(cudaDeviceSynchronize());
    if (mode) {
        Renderable3D_copyNormalToSurface<<<dim3(256, 256), dim3(16, 16)>>>(
                this, surf, texture_size, append);
    } else {
        Renderable3D_copyDepthToSurface<<<dim3(256, 256), dim3(16, 16)>>>(
                this, surf, texture_size, append);
    }
    CUDA_CHECK(cudaGetLastError());

    CUDA_CHECK(cudaDeviceSynchronize());
    CUDA_CHECK(cudaDestroySurfaceObject(surf));
    CUDA_CHECK(cudaGraphicsUnmapResources(1, &gl_tex));
}
