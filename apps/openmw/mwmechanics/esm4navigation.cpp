#include "esm4navigation.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <queue>

#include <components/debug/debuglog.hpp>
#include <components/esm4/loadnavm.hpp>

#include "../mwbase/environment.hpp"
#include "../mwworld/esmstore.hpp"

namespace MWMechanics
{
    namespace
    {
        // Twice the signed area of (a, b, c) in the XY plane: positive when c is left of a->b.
        float cross2D(const osg::Vec3f& a, const osg::Vec3f& b, const osg::Vec3f& c)
        {
            return (b.x() - a.x()) * (c.y() - a.y()) - (b.y() - a.y()) * (c.x() - a.x());
        }

        bool samePoint(const osg::Vec3f& a, const osg::Vec3f& b)
        {
            return (a - b).length2() < 1e-4f;
        }

        // How far corners keep off the navmesh border, so actors don't scrape walls.
        constexpr float sCornerMargin = 20.f;
        constexpr std::size_t sMaxExpansions = 30000;

        struct Portal
        {
            osg::Vec3f mLeft;
            osg::Vec3f mRight;
        };

        osg::Vec3f pullTowards(const osg::Vec3f& corner, const osg::Vec3f& other)
        {
            osg::Vec3f dir = other - corner;
            const float length = dir.length();
            if (length < 1e-3f)
                return corner;
            return corner + dir * (std::min(sCornerMargin, length * 0.5f) / length);
        }

        // "Simple stupid funnel": the shortest path through the portals, as its corners.
        std::vector<osg::Vec3f> stringPull(const std::vector<Portal>& portals)
        {
            std::vector<osg::Vec3f> points;
            if (portals.empty())
                return points;

            osg::Vec3f apex = portals[0].mLeft;
            osg::Vec3f left = portals[0].mLeft;
            osg::Vec3f right = portals[0].mRight;
            std::size_t apexIndex = 0, leftIndex = 0, rightIndex = 0;

            for (std::size_t i = 1; i < portals.size(); ++i)
            {
                const osg::Vec3f& newLeft = portals[i].mLeft;
                const osg::Vec3f& newRight = portals[i].mRight;

                // Narrow the right side of the funnel
                if (cross2D(apex, right, newRight) >= 0.f)
                {
                    if (samePoint(apex, right) || cross2D(apex, left, newRight) < 0.f)
                    {
                        right = newRight;
                        rightIndex = i;
                    }
                    else
                    {
                        // The right side crossed the left one: the left corner is on the path
                        apex = left;
                        apexIndex = leftIndex;
                        points.push_back(pullTowards(left, portals[leftIndex].mRight));
                        left = right = apex;
                        leftIndex = rightIndex = apexIndex;
                        i = apexIndex;
                        continue;
                    }
                }

                // Narrow the left side of the funnel
                if (cross2D(apex, left, newLeft) <= 0.f)
                {
                    if (samePoint(apex, left) || cross2D(apex, right, newLeft) > 0.f)
                    {
                        left = newLeft;
                        leftIndex = i;
                    }
                    else
                    {
                        apex = right;
                        apexIndex = rightIndex;
                        points.push_back(pullTowards(right, portals[rightIndex].mLeft));
                        left = right = apex;
                        leftIndex = rightIndex = apexIndex;
                        i = apexIndex;
                        continue;
                    }
                }
            }

            points.push_back(portals.back().mLeft);
            return points;
        }
    }

    void ESM4Navigation::buildIndex()
    {
        if (mIndexed)
            return;
        mIndexed = true;
        const MWWorld::ESMStore& store = *MWBase::Environment::get().getESMStore();
        for (const ESM4::NavMesh& mesh : store.get<ESM4::NavMesh>())
        {
            if (mesh.mFoTriangles.empty())
                continue;
            mMeshesByCell[mesh.mCell].push_back(&mesh);
            mMeshesById[mesh.mId] = &mesh;
        }
        Log(Debug::Info) << "ESM4 navigation: " << mMeshesById.size() << " navmeshes in " << mMeshesByCell.size()
                         << " cells";
    }

    const ESM4::NavMesh* ESM4Navigation::getMesh(ESM::FormId id) const
    {
        auto it = mMeshesById.find(id);
        return it == mMeshesById.end() ? nullptr : it->second;
    }

    bool ESM4Navigation::hasNavMesh(ESM::FormId cell)
    {
        buildIndex();
        return mMeshesByCell.contains(cell);
    }

    osg::Vec3f ESM4Navigation::vertex(const Triangle& triangle, int corner)
    {
        const ESM4::NavMesh::FoTriangle& tri = triangle.mMesh->mFoTriangles[triangle.mIndex];
        const ESM4::Vertex& v = triangle.mMesh->mFoVertices[tri.vertices[corner]];
        return osg::Vec3f(v.x, v.y, v.z);
    }

    osg::Vec3f ESM4Navigation::centroid(const Triangle& triangle)
    {
        return (vertex(triangle, 0) + vertex(triangle, 1) + vertex(triangle, 2)) / 3.f;
    }

    bool ESM4Navigation::contains2D(const Triangle& triangle, float x, float y)
    {
        const osg::Vec3f p(x, y, 0.f);
        const osg::Vec3f a = vertex(triangle, 0), b = vertex(triangle, 1), c = vertex(triangle, 2);
        const float d1 = cross2D(a, b, p), d2 = cross2D(b, c, p), d3 = cross2D(c, a, p);
        const bool hasNeg = d1 < 0.f || d2 < 0.f || d3 < 0.f;
        const bool hasPos = d1 > 0.f || d2 > 0.f || d3 > 0.f;
        return !(hasNeg && hasPos);
    }

    float ESM4Navigation::heightAt(const Triangle& triangle, float x, float y)
    {
        const osg::Vec3f a = vertex(triangle, 0), b = vertex(triangle, 1), c = vertex(triangle, 2);
        const osg::Vec3f normal = (b - a) ^ (c - a);
        if (std::abs(normal.z()) < 1e-6f)
            return std::max({ a.z(), b.z(), c.z() });
        return a.z() - (normal.x() * (x - a.x()) + normal.y() * (y - a.y())) / normal.z();
    }

    std::optional<ESM4Navigation::Triangle> ESM4Navigation::findTriangle(
        const ESM4::NavMesh& mesh, const osg::Vec3f& position) const
    {
        std::optional<Triangle> best;
        float bestScore = std::numeric_limits<float>::max();
        for (std::size_t i = 0; i < mesh.mFoTriangles.size(); ++i)
        {
            const Triangle triangle{ &mesh, static_cast<std::uint16_t>(i) };
            float score;
            if (contains2D(triangle, position.x(), position.y()))
                // Prefer the floor just below the position over the one above it (stairs, upper floors)
                score = std::abs(heightAt(triangle, position.x(), position.y()) - position.z() + 30.f);
            else
                score = 10000.f + (centroid(triangle) - position).length();
            if (score < bestScore)
            {
                bestScore = score;
                best = triangle;
            }
        }
        return best;
    }

    std::optional<ESM4Navigation::Triangle> ESM4Navigation::locate(ESM::FormId cell, const osg::Vec3f& position)
    {
        buildIndex();
        auto it = mMeshesByCell.find(cell);
        if (it == mMeshesByCell.end())
            return std::nullopt;
        std::optional<Triangle> best;
        float bestScore = std::numeric_limits<float>::max();
        for (const ESM4::NavMesh* mesh : it->second)
        {
            std::optional<Triangle> found = findTriangle(*mesh, position);
            if (!found)
                continue;
            float score;
            if (contains2D(*found, position.x(), position.y()))
                score = std::abs(heightAt(*found, position.x(), position.y()) - position.z() + 30.f);
            else
                score = 10000.f + (centroid(*found) - position).length();
            if (score < bestScore)
            {
                bestScore = score;
                best = found;
            }
        }
        return best;
    }

    void ESM4Navigation::getNeighbours(const Triangle& triangle, std::vector<Neighbour>& out) const
    {
        out.clear();
        const ESM4::NavMesh::FoTriangle& tri = triangle.mMesh->mFoTriangles[triangle.mIndex];
        const osg::Vec3f center = centroid(triangle);
        for (int k = 0; k < 3; ++k)
        {
            Triangle next;
            if (tri.flags & (1 << k))
            {
                if (tri.edges[k] < 0 || static_cast<std::size_t>(tri.edges[k]) >= triangle.mMesh->mFoExternal.size())
                    continue;
                const ESM4::NavMesh::FoExternal& external = triangle.mMesh->mFoExternal[tri.edges[k]];
                const ESM4::NavMesh* mesh = getMesh(ESM::FormId::fromUint32(external.navMesh));
                if (mesh == nullptr || external.triangle >= mesh->mFoTriangles.size())
                    continue;
                next = Triangle{ mesh, external.triangle };
            }
            else
            {
                if (tri.edges[k] < 0 || static_cast<std::size_t>(tri.edges[k]) >= triangle.mMesh->mFoTriangles.size())
                    continue;
                next = Triangle{ triangle.mMesh, static_cast<std::uint16_t>(tri.edges[k]) };
            }
            const osg::Vec3f p = vertex(triangle, k);
            const osg::Vec3f q = vertex(triangle, (k + 1) % 3);
            // Facing the edge from inside the triangle, the end to the left goes first
            if (cross2D(center, p, q) > 0.f)
                out.push_back(Neighbour{ next, q, p });
            else
                out.push_back(Neighbour{ next, p, q });
        }
    }

    std::optional<ESM4Navigation::Path> ESM4Navigation::findPath(
        ESM::FormId cell, const osg::Vec3f& from, const osg::Vec3f& to)
    {
        std::optional<Triangle> start = locate(cell, from);
        if (!start)
            return std::nullopt;
        // The goal may lie in a neighbouring exterior cell; look there by position through the start's cell first,
        // then let A* find whatever triangle contains it.
        std::optional<Triangle> goal = locate(cell, to);
        const bool goalInside = goal && contains2D(*goal, to.x(), to.y());

        struct Node
        {
            float mCost = 0.f;
            Triangle mParent;
            bool mHasParent = false;
            osg::Vec3f mLeft, mRight; // portal from the parent
            bool mClosed = false;
        };
        std::map<Triangle, Node> nodes;
        using Entry = std::pair<float, Triangle>;
        std::priority_queue<Entry, std::vector<Entry>, std::greater<>> open;

        nodes[*start] = Node{};
        open.emplace((centroid(*start) - to).length(), *start);

        std::optional<Triangle> reached;
        float bestDistance = std::numeric_limits<float>::max();
        std::optional<Triangle> closest;
        std::vector<Neighbour> neighbours;
        std::size_t expansions = 0;
        while (!open.empty() && expansions < sMaxExpansions)
        {
            const Triangle current = open.top().second;
            open.pop();
            Node& node = nodes[current];
            if (node.mClosed)
                continue;
            node.mClosed = true;
            ++expansions;

            if ((goalInside && current == *goal) || (!goalInside && contains2D(current, to.x(), to.y())))
            {
                reached = current;
                break;
            }
            const float distance = (centroid(current) - to).length();
            if (distance < bestDistance)
            {
                bestDistance = distance;
                closest = current;
            }

            const float cost = node.mCost;
            const osg::Vec3f center = centroid(current);
            getNeighbours(current, neighbours);
            for (const Neighbour& neighbour : neighbours)
            {
                const float newCost = cost + (centroid(neighbour.mTriangle) - center).length();
                auto [it, inserted] = nodes.try_emplace(neighbour.mTriangle);
                Node& next = it->second;
                if (next.mClosed || (!inserted && newCost >= next.mCost))
                    continue;
                next.mCost = newCost;
                next.mParent = current;
                next.mHasParent = true;
                next.mLeft = neighbour.mLeft;
                next.mRight = neighbour.mRight;
                open.emplace(newCost + (centroid(neighbour.mTriangle) - to).length(), neighbour.mTriangle);
            }
        }

        osg::Vec3f target = to;
        if (!reached)
        {
            // Unreachable goal (off the navmesh, or another island): go as near as the navmesh allows when that
            // is close, like the original engine does for markers placed just off the mesh.
            if (!closest || bestDistance > 512.f)
                return std::nullopt;
            reached = closest;
            target = centroid(*closest);
        }
        if (!contains2D(*reached, target.x(), target.y()))
            target = centroid(*reached);
        target.z() = heightAt(*reached, target.x(), target.y());

        Path path;
        std::vector<Portal> portals;
        for (Triangle t = *reached;;)
        {
            path.mCorridor.push_back(t);
            const Node& node = nodes[t];
            if (!node.mHasParent)
                break;
            portals.push_back(Portal{ node.mLeft, node.mRight });
            t = node.mParent;
        }
        std::reverse(path.mCorridor.begin(), path.mCorridor.end());
        std::reverse(portals.begin(), portals.end());

        osg::Vec3f origin = from;
        origin.z() = heightAt(*start, from.x(), from.y());
        portals.insert(portals.begin(), Portal{ origin, origin });
        portals.push_back(Portal{ target, target });
        path.mPoints = stringPull(portals);
        return path;
    }

    std::vector<ESM4Navigation::CoverEdge> ESM4Navigation::findCoverEdges(
        ESM::FormId cell, const osg::Vec3f& center, float radius, std::size_t maxCount)
    {
        std::vector<CoverEdge> result;
        std::optional<Triangle> start = locate(cell, center);
        if (!start)
            return result;
        // Breadth first from the center's triangle: the original walks the navmesh outward the same way
        std::vector<Triangle> found{ *start };
        std::map<Triangle, bool> seen{ { *start, true } };
        std::vector<Neighbour> neighbours;
        for (std::size_t i = 0; i < found.size() && found.size() < 8192 && result.size() < maxCount; ++i)
        {
            const Triangle& triangle = found[i];
            const ESM4::NavMesh::FoTriangle& tri = triangle.mMesh->mFoTriangles[triangle.mIndex];
            // Cover flags [inferred from xEdit's NVTR layout]: bits 0-3 cover value of edge 0-1, 4 left open,
            // 5 right open; bits 6-9, 10 and 11 the same for edge 1-2
            for (int k = 0; k < 2; ++k)
            {
                const int bits = (tri.coverFlags >> (6 * k)) & 0x3f;
                const int height = bits & 0xf;
                if (height == 0)
                    continue;
                CoverEdge edge;
                edge.mA = vertex(triangle, k);
                edge.mB = vertex(triangle, k + 1);
                edge.mOpenA = (bits & 0x10) != 0;
                edge.mOpenB = (bits & 0x20) != 0;
                edge.mHeight = height;
                osg::Vec3f mid = (edge.mA + edge.mB) * 0.5f;
                osg::Vec3f inward = centroid(triangle) - mid;
                inward.z() = 0.f;
                if (inward.normalize() == 0.f)
                    continue;
                edge.mInward = inward;
                edge.mKey = (static_cast<std::uint64_t>(triangle.mMesh->mId.toUint32()) << 32)
                    | (static_cast<std::uint64_t>(triangle.mIndex) << 2) | static_cast<std::uint64_t>(k);
                result.push_back(edge);
            }
            getNeighbours(triangle, neighbours);
            for (const Neighbour& neighbour : neighbours)
            {
                if (seen.contains(neighbour.mTriangle))
                    continue;
                seen[neighbour.mTriangle] = true;
                if ((centroid(neighbour.mTriangle) - center).length() <= radius)
                    found.push_back(neighbour.mTriangle);
            }
        }
        return result;
    }

    std::optional<osg::Vec3f> ESM4Navigation::randomPoint(
        ESM::FormId cell, const osg::Vec3f& center, float radius, std::mt19937& rng)
    {
        std::optional<Triangle> start = locate(cell, center);
        if (!start)
            return std::nullopt;

        // Flood the navmesh from the center's triangle within the radius, then pick a triangle weighted by area.
        std::vector<Triangle> found{ *start };
        std::map<Triangle, bool> seen{ { *start, true } };
        std::vector<Neighbour> neighbours;
        for (std::size_t i = 0; i < found.size() && found.size() < 4096; ++i)
        {
            getNeighbours(found[i], neighbours);
            for (const Neighbour& neighbour : neighbours)
            {
                if (seen.contains(neighbour.mTriangle))
                    continue;
                seen[neighbour.mTriangle] = true;
                if ((centroid(neighbour.mTriangle) - center).length() <= radius)
                    found.push_back(neighbour.mTriangle);
            }
        }

        std::vector<float> areas;
        areas.reserve(found.size());
        for (const Triangle& t : found)
        {
            const osg::Vec3f a = vertex(t, 0), b = vertex(t, 1), c = vertex(t, 2);
            areas.push_back(std::abs(cross2D(a, b, c)) * 0.5f + 1.f);
        }
        std::discrete_distribution<std::size_t> pickTriangle(areas.begin(), areas.end());
        const Triangle& t = found[pickTriangle(rng)];
        std::uniform_real_distribution<float> unit(0.f, 1.f);
        float u = unit(rng), v = unit(rng);
        if (u + v > 1.f)
        {
            u = 1.f - u;
            v = 1.f - v;
        }
        const osg::Vec3f a = vertex(t, 0), b = vertex(t, 1), c = vertex(t, 2);
        // Keep away from the edges a little
        const osg::Vec3f mid = (a + b + c) / 3.f;
        osg::Vec3f point = a + (b - a) * u + (c - a) * v;
        point = mid + (point - mid) * 0.8f;
        point.z() = heightAt(t, point.x(), point.y());
        return point;
    }
}
