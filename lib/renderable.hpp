#pragma once
#include <cuda_gl_interop.h>
#include <cuda_runtime.h>
#include <libfive/tree/tree.hpp>

#include "check.hpp"
#include "clause.hpp"
#include "gpu_interval.hpp"
#include "gpu_deriv.hpp"
#include "image.hpp"
#include "parameters.hpp"
#include "subtapes.hpp"
#include "tape.hpp"
#include "tiles.hpp"
#include "view.hpp"

template <unsigned TILE_SIZE_PX, unsigned DIMENSION>
class TileRenderer {
public:
    TileRenderer(const Tape& tape, Subtapes& subtapes, Image& image);

    // Evaluates the given tile.
    //      Filled -> Pushes it to the list of filed tiles
    //      Ambiguous -> Pushes it to the list of active tiles and builds tape
    //      Empty -> Does nothing
    //  Reverses the tapes
    __device__ void check(const uint32_t tile, const View& v);

    const Tape& tape;
    Image& image;

    Tiles<TILE_SIZE_PX, DIMENSION> tiles;

protected:
    Subtapes& subtapes;

    TileRenderer(const TileRenderer& other)=delete;
    TileRenderer& operator=(const TileRenderer& other)=delete;
};

////////////////////////////////////////////////////////////////////////////////

template <unsigned TILE_SIZE_PX, unsigned SUBTILE_SIZE_PX, unsigned DIMENSION>
class SubtileRenderer {
public:
    SubtileRenderer(const Tape& tape, Subtapes& subtapes, Image& image,
                    Tiles<TILE_SIZE_PX, DIMENSION>& prev);

    constexpr static unsigned __host__ __device__ subtilesPerTileSide() {
        static_assert(TILE_SIZE_PX % SUBTILE_SIZE_PX == 0,
                      "Cannot evenly divide tiles into subtiles");
        return TILE_SIZE_PX / SUBTILE_SIZE_PX;
    }
    constexpr static unsigned __host__ __device__ subtilesPerTile() {
        return pow(subtilesPerTileSide(), DIMENSION);
    }

    // Same functions as in TileRenderer, but these take a subtape because
    // they're refining a tile into subtiles
    __device__ void check(
            const uint32_t subtile,
            const uint32_t tile,
            const View& v);

    // Refines a tile tape into a subtile tape based on choices
    __device__ void buildTape(const uint32_t subtile,
                              const uint32_t tile);
    const Tape& tape;
    Image& image;

    // Reference to tiles generated in previous stage
    Tiles<TILE_SIZE_PX, DIMENSION>& tiles;

    // New tiles generated in this stage
    Tiles<SUBTILE_SIZE_PX, DIMENSION> subtiles;

protected:
    Subtapes& subtapes;

    SubtileRenderer(const SubtileRenderer& other)=delete;
    SubtileRenderer& operator=(const SubtileRenderer& other)=delete;
};

////////////////////////////////////////////////////////////////////////////////

template <unsigned SUBTILE_SIZE_PX, unsigned DIMENSION>
class PixelRenderer {
public:
    PixelRenderer(const Tape& tape, const Subtapes& subtapes, Image& image,
                  const Tiles<SUBTILE_SIZE_PX, DIMENSION>& prev);

    constexpr static bool __host__ __device__ is3D() {
        return DIMENSION == 3;
    }

    constexpr static unsigned __host__ __device__ pixelsPerSubtile() {
        return pow(SUBTILE_SIZE_PX, DIMENSION);
    }

    // Draws the given tile, starting from the given subtape
    __device__ void draw(const uint32_t subtile, const View& v);

    const Tape& tape;
    Image& image;

    // Reference to tiles generated in previous stage
    const Tiles<SUBTILE_SIZE_PX, DIMENSION>& subtiles;

protected:
    const Subtapes& subtapes;

    PixelRenderer(const PixelRenderer& other)=delete;
    PixelRenderer& operator=(const PixelRenderer& other)=delete;
};

////////////////////////////////////////////////////////////////////////////////

class Renderable; // forward declaration
class NormalRenderer {
public:
    NormalRenderer(const Tape& tape, const Renderable& parent, Image& norm);

    // Draws the given pixel, pulling height from the image
    __device__ void draw(const uint2 p, const View& v);

    const Tape& tape;
    const Renderable& parent;
    Image& norm;
protected:
    NormalRenderer(const NormalRenderer& other)=delete;
    NormalRenderer& operator=(const NormalRenderer& other)=delete;
};

////////////////////////////////////////////////////////////////////////////////

class Renderable {
public:
    class Deleter {
    public:
        void operator()(Renderable* r);
    };

    using Handle = std::unique_ptr<Renderable, Deleter>;

    // Returns a GPU-allocated Renderable struct
    static Handle build(libfive::Tree tree, uint32_t image_size_px);
    void run(const View& v);

    static cudaGraphicsResource* registerTexture(GLuint t);
    void copyToTexture(cudaGraphicsResource* gl_tex, bool append);

    __device__
    void copyToSurface(bool append, cudaSurfaceObject_t surf);

    __host__ __device__
    uint32_t heightAt(const uint32_t x, const uint32_t y) const;

    Image image;
    Image norm;
    Tape tape;

protected:
    Renderable(libfive::Tree tree, uint32_t image_size_px);
    ~Renderable();

    cudaStream_t streams[LIBFIVE_CUDA_NUM_STREAMS];

#if LIBFIVE_CUDA_3D
    TileRenderer<64, 3> tile_renderer;
    SubtileRenderer<64, 16, 3> subtile_renderer;
    SubtileRenderer<16, 4, 3> microtile_renderer;
    PixelRenderer<4, 3> pixel_renderer;
    NormalRenderer normal_renderer;

    bool has_normals;
#else
    TileRenderer<64, 2> tile_renderer;
    SubtileRenderer<64, 8, 2> subtile_renderer;
    PixelRenderer<8, 2> pixel_renderer;
#endif

    Subtapes subtapes;

    Renderable(const Renderable& other)=delete;
    Renderable& operator=(const Renderable& other)=delete;
};
