#ifndef GAME_MWMECHANICS_ESM4NAVIGATION_H
#define GAME_MWMECHANICS_ESM4NAVIGATION_H

#include <cstdint>
#include <map>
#include <optional>
#include <random>
#include <vector>

#include <osg/Vec3f>

#include <components/esm/formid.hpp>

namespace ESM4
{
    struct NavMesh;
}

namespace MWMechanics
{
    // Pathfinding over the navmeshes that FO3/FONV ship with their cells (NAVM records). Triangles of one navmesh
    // link through their edge neighbours, navmeshes of neighbouring exterior cells through external connections.
    class ESM4Navigation
    {
    public:
        struct Triangle
        {
            const ESM4::NavMesh* mMesh = nullptr;
            std::uint16_t mIndex = 0;

            bool operator==(const Triangle& other) const = default;
            auto operator<=>(const Triangle& other) const = default;
        };

        struct Path
        {
            std::vector<osg::Vec3f> mPoints; // corners from start (excluded) to the goal
            std::vector<Triangle> mCorridor; // triangles crossed, start to goal
        };

        // Whether the cell has a navmesh at all.
        bool hasNavMesh(ESM::FormId cell);

        // Triangle under (or nearest to) the position, searched in the navmeshes of the cell.
        std::optional<Triangle> locate(ESM::FormId cell, const osg::Vec3f& position);

        // Straightened path between two points of the cell's navmeshes; may leave the cell through exterior
        // connections. Nullopt when no route exists.
        std::optional<Path> findPath(ESM::FormId cell, const osg::Vec3f& from, const osg::Vec3f& to);

        // Random point on the navmesh within radius of center, reachable from center's triangle.
        std::optional<osg::Vec3f> randomPoint(
            ESM::FormId cell, const osg::Vec3f& center, float radius, std::mt19937& rng);

        // A navmesh edge marked as cover (NVTR cover flags), as the original's cover search sees it.
        struct CoverEdge
        {
            osg::Vec3f mA, mB; // ends
            osg::Vec3f mInward; // horizontal unit vector from the edge into its triangle (the side to stand on)
            bool mOpenA = false, mOpenB = false; // whether the actor can step out past that end
            int mHeight = 0; // cover value 1-15
            std::uint64_t mKey = 0; // navmesh, triangle and edge, for reservations
        };

        // Cover edges in the navmeshes around center, nearest first along the navmesh (a flood from center's
        // triangle within radius), at most maxCount.
        std::vector<CoverEdge> findCoverEdges(
            ESM::FormId cell, const osg::Vec3f& center, float radius, std::size_t maxCount);

        // Height of the triangle's plane at (x, y).
        static float heightAt(const Triangle& triangle, float x, float y);
        static bool contains2D(const Triangle& triangle, float x, float y);
        static osg::Vec3f vertex(const Triangle& triangle, int corner);
        static osg::Vec3f centroid(const Triangle& triangle);

    private:
        struct Neighbour
        {
            Triangle mTriangle;
            osg::Vec3f mLeft; // portal ends, as seen moving from the current triangle into the neighbour
            osg::Vec3f mRight;
        };

        void buildIndex();
        const ESM4::NavMesh* getMesh(ESM::FormId id) const;
        void getNeighbours(const Triangle& triangle, std::vector<Neighbour>& out) const;
        std::optional<Triangle> findTriangle(const ESM4::NavMesh& mesh, const osg::Vec3f& position) const;

        bool mIndexed = false;
        std::map<ESM::FormId, std::vector<const ESM4::NavMesh*>> mMeshesByCell;
        std::map<ESM::FormId, const ESM4::NavMesh*> mMeshesById;
    };
}

#endif
