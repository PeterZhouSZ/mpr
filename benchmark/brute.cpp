#include <cstdio>
#include <chrono>
#include <iostream>
#include <fstream>

// libfive
#include <libfive/tree/tree.hpp>
#include <libfive/tree/archive.hpp>
#include <libfive/render/discrete/heightmap.hpp>

#include "renderable.hpp"

int main(int argc, char **argv)
{
    libfive::Tree t = libfive::Tree::X();
    if (argc == 2) {
        std::ifstream ifs;
        ifs.open(argv[1]);
        if (ifs.is_open()) {
            auto a = libfive::Archive::deserialize(ifs);
            t = a.shapes.front().tree;
        } else {
            fprintf(stderr, "Could not open file %s\n", argv[1]);
            exit(1);
        }
    } else {
        auto X = libfive::Tree::X();
        auto Y = libfive::Tree::Y();
        auto Z = libfive::Tree::Z();
        t = min(sqrt((X + 0.5)*(X + 0.5) + Y*Y + Z*Z) - 0.25,
                sqrt((X - 0.5)*(X - 0.5) + Y*Y + Z*Z) - 0.25);
    }

    std::cout << "Rendering brute-force with interpreter\n";
    for (unsigned i=256; i <= 2048; i += 64)
    {
        auto r_ = Renderable::build(t, i, 2);
        auto r = dynamic_cast<Renderable2D*>(r_.get());
        // Warm up
        for (unsigned i=0; i < 10; ++i) {
            r->runBrute({Eigen::Matrix4f::Identity()});
        }
        // Benchmark
        std::vector<double> times_ms;
        for (unsigned i=0; i < 50; ++i) {
            auto start_gpu = std::chrono::steady_clock::now();
            r->runBrute({Eigen::Matrix4f::Identity()});
            auto end_gpu = std::chrono::steady_clock::now();
            times_ms.push_back(
                    std::chrono::duration_cast<std::chrono::nanoseconds>(end_gpu - start_gpu).count()
                    / 1e6
                    );
        }
        double mean = 0;
        for (auto& b : times_ms) {
            mean += b;
        }
        mean /= times_ms.size();
        double stdev = 0;
        for (auto& b : times_ms) {
            stdev += std::pow(b - mean, 2);
        }
        stdev = sqrt(stdev / (times_ms.size() - 1));
        std::cout << i << " " << mean << " " << stdev << "\n";

        // Save the image using libfive::Heightmap
        libfive::Heightmap out(r->image.size_px, r->image.size_px);
        for (unsigned x=0; x < r->image.size_px; ++x) {
            for (unsigned y=0; y < r->image.size_px; ++y) {
                out.depth(y, x) = r->heightAt(x, y);
            }
        }
        out.savePNG("out_brute_" + std::to_string(i) + ".png");
    }
    return 0;

    std::cout << "Rendering hard-compiled kernel\n";
    for (unsigned i=256; i <= 4096; i += 64)
    {
        auto r_ = Renderable::build(t, i, 2);
        auto r = dynamic_cast<Renderable2D*>(r_.get());
        // Warm up
        for (unsigned i=0; i < 10; ++i) {
            r->runBruteKernel({Eigen::Matrix4f::Identity()});
        }
        // Benchmark
        std::vector<double> times_ms;
        for (unsigned i=0; i < 100; ++i) {
            auto start_gpu = std::chrono::steady_clock::now();
            r->runBruteKernel({Eigen::Matrix4f::Identity()});
            auto end_gpu = std::chrono::steady_clock::now();
            times_ms.push_back(
                    std::chrono::duration_cast<std::chrono::nanoseconds>(end_gpu - start_gpu).count()
                    / 1e6
                    );
        }
        double mean = 0;
        for (auto& b : times_ms) {
            mean += b;
        }
        mean /= times_ms.size();
        double stdev = 0;
        for (auto& b : times_ms) {
            stdev += std::pow(b - mean, 2);
        }
        stdev = sqrt(stdev / (times_ms.size() - 1));
        std::cout << i << " " << mean << " " << stdev << "\n";

        // Save the image using libfive::Heightmap
        libfive::Heightmap out(r->image.size_px, r->image.size_px);
        for (unsigned x=0; x < r->image.size_px; ++x) {
            for (unsigned y=0; y < r->image.size_px; ++y) {
                out.depth(y, x) = r->heightAt(x, y);
            }
        }
        out.savePNG("out_kernel_" + std::to_string(i) + ".png");
    }

    std::cout << "Rendering fancy algorithm with interpreter\n";
    for (unsigned i=256; i <= 4096; i += 64)
    {
        auto r_ = Renderable::build(t, i, 2);
        auto r = dynamic_cast<Renderable2D*>(r_.get());
        for (unsigned i=0; i < 10; ++i) {
            r->run({Eigen::Matrix4f::Identity()}, Renderable::MODE_HEIGHTMAP);
        }
        // Benchmark
        std::vector<double> times_ms;
        for (unsigned i=0; i < 100; ++i) {
            auto start_gpu = std::chrono::steady_clock::now();
            r->run({Eigen::Matrix4f::Identity()}, Renderable::MODE_HEIGHTMAP);
            auto end_gpu = std::chrono::steady_clock::now();
            times_ms.push_back(
                    std::chrono::duration_cast<std::chrono::nanoseconds>(end_gpu - start_gpu).count()
                    / 1e6
                    );
        }
        double mean = 0;
        for (auto& b : times_ms) {
            mean += b;
        }
        mean /= times_ms.size();
        double stdev = 0;
        for (auto& b : times_ms) {
            stdev += std::pow(b - mean, 2);
        }
        stdev = sqrt(stdev / (times_ms.size() - 1));
        std::cout << i << " " << mean << " " << stdev << "\n";

        // Save the image using libfive::Heightmap
        libfive::Heightmap out(r->image.size_px, r->image.size_px);
        for (unsigned x=0; x < r->image.size_px; ++x) {
            for (unsigned y=0; y < r->image.size_px; ++y) {
                out.depth(y, x) = r->heightAt(x, y);
            }
        }
        out.savePNG("out_alg_" + std::to_string(i) + ".png");
    }
}
