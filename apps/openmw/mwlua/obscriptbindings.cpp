#include "obscriptbindings.hpp"

#include <atomic>
#include <cstdlib>
#include <map>
#include <mutex>
#include <set>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

#include <sol/state_view.hpp>
#include <sol/table.hpp>
#include <sol/usertype.hpp>

#include <components/debug/debuglog.hpp>
#include <components/esm/refid.hpp>
#include <components/esm4/loadachr.hpp>
#include <components/esm4/loadacti.hpp>
#include <components/esm4/loadalch.hpp>
#include <components/esm4/loadammo.hpp>
#include <components/esm4/loadarmo.hpp>
#include <components/esm4/loadbook.hpp>
#include <components/esm4/loadcell.hpp>
#include <components/esm4/loadclot.hpp>
#include <components/esm4/loadcont.hpp>
#include <components/esm4/loadcrea.hpp>
#include <components/esm4/loaddoor.hpp>
#include <components/esm4/loadfact.hpp>
#include <components/esm4/loadingr.hpp>
#include <components/esm4/loadkeym.hpp>
#include <components/esm4/loadligh.hpp>
#include <components/esm4/loadlvlc.hpp>
#include <components/esm4/loadlvli.hpp>
#include <components/esm4/loadlvln.hpp>
#include <components/esm4/loadmesg.hpp>
#include <components/esm4/loadmisc.hpp>
#include <components/esm4/loadmstt.hpp>
#include <components/esm4/loadnote.hpp>
#include <components/esm4/loadnpc.hpp>
#include <components/esm4/loadpack.hpp>
#include <components/esm4/loadrefr.hpp>
#include <components/esm4/loadscpt.hpp>
#include <components/esm4/loadsoun.hpp>
#include <components/esm4/loadstat.hpp>
#include <components/esm4/loadweap.hpp>
#include <components/esm4/loadwrld.hpp>
#include <components/lua/luastate.hpp>
#include <components/lua/util.hpp>
#include <components/misc/strings/lower.hpp>
#include <components/myguiplatform/myguirendermanager.hpp>

#include <MyGUI_Types.h>
#include <osg/Texture2D>

#include "../mwbase/environment.hpp"
#include "../mwbase/windowmanager.hpp"
#include "../mwbase/world.hpp"
#include "../mwmechanics/creaturestats.hpp"
#include "../mwworld/class.hpp"
#include "../mwworld/containerstore.hpp"
#include "../mwclass/esm4base.hpp"
#include "../mwclass/esm4door.hpp"
#include "../mwworld/cellstore.hpp"
#include "../mwworld/scene.hpp"
#include "../mwrender/localmap.hpp"
#include "../mwworld/esmstore.hpp"
#include "../mwworld/globals.hpp"
#include "../mwworld/store.hpp"
#include "../mwworld/worldmodel.hpp"

#include "context.hpp"
#include "luamanagerimp.hpp"
#include "object.hpp"
#include "obscriptaibindings.hpp"
#include "obscriptcombatbindings.hpp"
#include "obscriptphysicalbindings.hpp"
#include "obscriptdialoguebindings.hpp"
#include "obscriptradiobindings.hpp"
#include "obscripteffectbindings.hpp"
#include "obscriptstatsbindings.hpp"

namespace sol
{
    template <>
    struct is_automagical<ESM4::Script> : std::false_type
    {
    };

    template <>
    struct is_automagical<MWWorld::Store<ESM4::Script>> : std::false_type
    {
    };
}

namespace MWLua
{
    sol::table initCoreObScriptBindings(const Context& context)
    {
        sol::state_view lua = context.sol();
        sol::table api(lua, sol::create);

        auto recordBindingsClass = lua.new_usertype<ESM4::Script>("ESM4_Script");
        recordBindingsClass[sol::meta_function::to_string]
            = [](const ESM4::Script& rec) { return "ESM4_Script[" + ESM::RefId(rec.mId).toDebugString() + "]"; };
        recordBindingsClass["id"] = sol::readonly_property(
            [](const ESM4::Script& rec) -> std::string { return ESM::RefId(rec.mId).serializeText(); });
        recordBindingsClass["editorId"]
            = sol::readonly_property([](const ESM4::Script& rec) -> std::string_view { return rec.mEditorId; });
        recordBindingsClass["text"] = sol::readonly_property(
            [](const ESM4::Script& rec) -> std::string_view { return rec.mScript.scriptSource; });

        using StoreT = MWWorld::Store<ESM4::Script>;
        sol::usertype<StoreT> storeBindingsClass = lua.new_usertype<StoreT>("ESM4_Script Store");
        storeBindingsClass[sol::meta_function::to_string]
            = [](const StoreT& store) { return "{" + std::to_string(store.getSize()) + " ESM4_Script records}"; };
        storeBindingsClass[sol::meta_function::length] = [](const StoreT& store) { return store.getSize(); };
        storeBindingsClass[sol::meta_function::index] = sol::overload(
            [](const StoreT& store, size_t index) -> const ESM4::Script* {
                if (index == 0 || index > store.getSize())
                    return nullptr;
                return store.at(LuaUtil::fromLuaIndex(index));
            },
            [](const StoreT& store, std::string_view id) -> const ESM4::Script* {
                return store.search(ESM::RefId::deserializeText(id));
            });
        storeBindingsClass[sol::meta_function::ipairs] = lua["ipairsForArray"].get<sol::function>();
        storeBindingsClass[sol::meta_function::pairs] = lua["ipairsForArray"].get<sol::function>();

        api["records"] = &MWBase::Environment::get().getESMStore()->get<ESM4::Script>();

        // Case-insensitive editor-id lookup, built lazily on first use.
        using EditorIdIndex = std::map<std::string, ESM::RefId>;
        auto resolve = [](const EditorIdIndex& index, std::string_view editorId) -> sol::optional<std::string> {
            auto it = index.find(Misc::StringUtils::lowerCase(editorId));
            if (it == index.end())
                return sol::nullopt;
            return it->second.serializeText();
        };

        // Item record types, for ObScript arguments like `player.AddItem <EditorId> <count>`.
        api["resolveItemEditorId"] = [resolve](std::string_view editorId) {
            static const EditorIdIndex index = [] {
                EditorIdIndex res;
                const MWWorld::ESMStore& store = *MWBase::Environment::get().getESMStore();
                auto addAll = [&](const auto& s) {
                    for (size_t i = 0; i < s.getSize(); ++i)
                    {
                        const auto& record = *s.at(i);
                        if (!record.mEditorId.empty())
                            res.emplace(Misc::StringUtils::lowerCase(record.mEditorId), ESM::RefId(record.mId));
                    }
                };
                addAll(store.get<ESM4::Ammunition>());
                addAll(store.get<ESM4::Armor>());
                addAll(store.get<ESM4::Book>());
                addAll(store.get<ESM4::Clothing>());
                addAll(store.get<ESM4::Ingredient>());
                addAll(store.get<ESM4::Key>());
                addAll(store.get<ESM4::MiscItem>());
                addAll(store.get<ESM4::Potion>());
                addAll(store.get<ESM4::Weapon>());
                addAll(store.get<ESM4::LevelledItem>());
                return res;
            }();
            return resolve(index, editorId);
        };

        // The items `AddItem <LevelledList> <count>` gives the player: a levelled item list (LVLI) is rolled at
        // the player's level; other items come back as they are. A list of { id = recordId, count = n }.
        api["resolveLevelledItem"] = [](std::string_view recordId, int count, sol::this_state s) -> sol::table {
            sol::state_view lua(s);
            sol::table res(lua, sol::create);
            int level = 1;
            const MWWorld::Ptr player = MWBase::Environment::get().getWorld()->getPlayerPtr();
            if (!player.isEmpty())
                level = player.getClass().getCreatureStats(player).getLevel();
            const auto items = MWWorld::ContainerStore::resolveESM4Items(ESM::RefId::deserializeText(recordId),
                count, level, MWBase::Environment::get().getWorld()->getPrng());
            for (size_t i = 0; i < items.size(); ++i)
            {
                sol::table item(lua, sol::create);
                item["id"] = items[i].first.serializeText();
                item["count"] = items[i].second;
                res[LuaUtil::toLuaIndex(i)] = item;
            }
            return res;
        };

        // Base records that can be placed in the world (`PlaceAtMe <EditorId>`): items, actors, leveled
        // actors and placeable objects.
        api["resolveBaseEditorId"] = [resolve](std::string_view editorId) {
            static const EditorIdIndex index = [] {
                EditorIdIndex res;
                const MWWorld::ESMStore& store = *MWBase::Environment::get().getESMStore();
                auto addAll = [&](const auto& s) {
                    for (size_t i = 0; i < s.getSize(); ++i)
                    {
                        const auto& record = *s.at(i);
                        if (!record.mEditorId.empty())
                            res.emplace(Misc::StringUtils::lowerCase(record.mEditorId), ESM::RefId(record.mId));
                    }
                };
                addAll(store.get<ESM4::Ammunition>());
                addAll(store.get<ESM4::Armor>());
                addAll(store.get<ESM4::Book>());
                addAll(store.get<ESM4::Ingredient>());
                addAll(store.get<ESM4::Key>());
                addAll(store.get<ESM4::MiscItem>());
                addAll(store.get<ESM4::Potion>());
                addAll(store.get<ESM4::Weapon>());
                addAll(store.get<ESM4::Npc>());
                addAll(store.get<ESM4::Creature>());
                addAll(store.get<ESM4::LevelledNpc>());
                addAll(store.get<ESM4::LevelledCreature>());
                addAll(store.get<ESM4::Activator>());
                addAll(store.get<ESM4::Container>());
                addAll(store.get<ESM4::Light>());
                addAll(store.get<ESM4::Static>());
                addAll(store.get<ESM4::MovableStatic>());
                return res;
            }();
            return resolve(index, editorId);
        };

        // Factions, for `AddToFaction <EditorId> <rank>` and friends.
        api["resolveFactionEditorId"] = [resolve](std::string_view editorId) {
            static const EditorIdIndex index = [] {
                EditorIdIndex res;
                const MWWorld::Store<ESM4::Faction>& factions
                    = MWBase::Environment::get().getESMStore()->get<ESM4::Faction>();
                for (size_t i = 0; i < factions.getSize(); ++i)
                {
                    const ESM4::Faction& faction = *factions.at(i);
                    if (!faction.mEditorId.empty())
                        res.emplace(Misc::StringUtils::lowerCase(faction.mEditorId), ESM::RefId(faction.mId));
                }
                return res;
            }();
            return resolve(index, editorId);
        };

        // AI packages, for `AddScriptPackage <EditorId>`.
        api["resolvePackageEditorId"] = [resolve](std::string_view editorId) {
            static const EditorIdIndex index = [] {
                EditorIdIndex res;
                const MWWorld::Store<ESM4::AIPackage>& packages
                    = MWBase::Environment::get().getESMStore()->get<ESM4::AIPackage>();
                for (size_t i = 0; i < packages.getSize(); ++i)
                {
                    const ESM4::AIPackage& package = *packages.at(i);
                    if (!package.mEditorId.empty())
                        res.emplace(Misc::StringUtils::lowerCase(package.mEditorId), ESM::RefId(package.mId));
                }
                return res;
            }();
            return resolve(index, editorId);
        };

        // Persistent placed references (e.g. `GSSchoolTerminal01Ref.Disable`).
        // Notes, for `AddNote <EditorId>`.
        api["resolveNoteEditorId"] = [resolve](std::string_view editorId) {
            static const EditorIdIndex index = [] {
                EditorIdIndex res;
                const MWWorld::Store<ESM4::Note>& notes = MWBase::Environment::get().getESMStore()->get<ESM4::Note>();
                for (size_t i = 0; i < notes.getSize(); ++i)
                {
                    const ESM4::Note& note = *notes.at(i);
                    if (!note.mEditorId.empty())
                        res.emplace(Misc::StringUtils::lowerCase(note.mEditorId), ESM::RefId(note.mId));
                }
                return res;
            }();
            return resolve(index, editorId);
        };

        api["resolveRefEditorId"] = [resolve](std::string_view editorId) {
            static const EditorIdIndex index = [] {
                EditorIdIndex res;
                const MWWorld::ESMStore& store = *MWBase::Environment::get().getESMStore();
                // placed objects, NPCs and creatures (REFR, ACHR, ACRE)
                auto addAll = [&](const auto& refs) {
                    for (size_t i = 0; i < refs.getSize(); ++i)
                    {
                        const auto& ref = *refs.at(i);
                        if (!ref.mEditorId.empty())
                            res.emplace(Misc::StringUtils::lowerCase(ref.mEditorId), ESM::RefId(ref.mId));
                    }
                };
                addAll(store.get<ESM4::Reference>());
                addAll(store.get<ESM4::ActorCharacter>());
                addAll(store.get<ESM4::ActorCreature>());
                return res;
            }();
            return resolve(index, editorId);
        };

        // Sound records (SOUN), e.g. the HUD's `UIQuestNew`.
        api["resolveSoundEditorId"] = [resolve](std::string_view editorId) {
            static const EditorIdIndex index = [] {
                EditorIdIndex res;
                const MWWorld::Store<ESM4::Sound>& sounds = MWBase::Environment::get().getESMStore()->get<ESM4::Sound>();
                for (size_t i = 0; i < sounds.getSize(); ++i)
                {
                    const ESM4::Sound& sound = *sounds.at(i);
                    if (!sound.mEditorId.empty())
                        res.emplace(Misc::StringUtils::lowerCase(sound.mEditorId), ESM::RefId(sound.mId));
                }
                return res;
            }();
            return resolve(index, editorId);
        };

        // Where a placed reference (REFR, ACHR, ACRE) starts, from its record, so that scripts can find it while its
        // cell isn't loaded: { position, cell = cell id, isExterior, worldSpaceId }, or nil.
        api["getReferenceLocation"] = [](std::string_view formId, sol::this_state s) -> sol::object {
            const ESM::RefId refId = ESM::RefId::deserializeText(formId);
            const ESM::FormId* formIdPtr = refId.getIf<ESM::FormId>();
            if (formIdPtr == nullptr)
                return sol::nil;
            const ESM::FormId id = *formIdPtr;
            const MWWorld::ESMStore& store = *MWBase::Environment::get().getESMStore();
            const ESM::Position* pos = nullptr;
            ESM::RefId parent;
            if (const ESM4::Reference* ref = store.get<ESM4::Reference>().search(id))
            {
                pos = &ref->mPos;
                parent = ref->mParent;
            }
            else if (const ESM4::ActorCharacter* achr = store.get<ESM4::ActorCharacter>().search(id))
            {
                pos = &achr->mPos;
                parent = achr->mParent;
            }
            else if (const ESM4::ActorCreature* acre = store.get<ESM4::ActorCreature>().search(id))
            {
                pos = &acre->mPos;
                parent = acre->mParent;
            }
            const ESM4::Cell* cell = pos ? store.get<ESM4::Cell>().search(parent) : nullptr;
            if (cell == nullptr)
                return sol::nil;
            sol::state_view lua(s);
            sol::table res(lua, sol::create);
            res["position"] = pos->asVec3();
            res["cell"] = cell->mId.serializeText();
            res["isExterior"] = cell->isExterior();
            res["worldSpaceId"] = cell->isExterior() ? cell->mParent.serializeText() : std::string();
            return res;
        };

        // Message boxes (MESG) for `ShowMessage <EditorId> [args...]`.
        // Returns { title=, text=, buttons={...}, messageBox=bool, displayTime=n } or nil.
        api["getMessage"] = [lua](std::string_view editorId) -> sol::object {
            static const EditorIdIndex index = [] {
                EditorIdIndex res;
                const MWWorld::ESMStore& store = *MWBase::Environment::get().getESMStore();
                const MWWorld::Store<ESM4::Message>& msgs = store.get<ESM4::Message>();
                for (size_t i = 0; i < msgs.getSize(); ++i)
                {
                    const ESM4::Message& msg = *msgs.at(i);
                    if (!msg.mEditorId.empty())
                        res.emplace(Misc::StringUtils::lowerCase(msg.mEditorId), ESM::RefId(msg.mId));
                }
                return res;
            }();
            auto it = index.find(Misc::StringUtils::lowerCase(editorId));
            if (it == index.end())
                return sol::nil;
            const ESM4::Message* msg
                = MWBase::Environment::get().getESMStore()->get<ESM4::Message>().search(it->second);
            if (msg == nullptr)
                return sol::nil;
            sol::table res(lua, sol::create);
            res["title"] = msg->mFullName;
            res["text"] = msg->mText;
            res["messageBox"] = (msg->mMessageFlags & ESM4::Message::Flag_MessageBox) != 0;
            res["displayTime"] = msg->mDisplayTime;
            sol::table buttons(lua, sol::create);
            for (size_t i = 0; i < msg->mButtons.size(); ++i)
                buttons[LuaUtil::toLuaIndex(i)] = msg->mButtons[i];
            res["buttons"] = buttons;
            return res;
        };

        // Half extents of a placed trigger volume (REFR XPRM), nil when the reference has none.
        api["getPrimitiveBounds"] = [](const Object& object) -> sol::optional<osg::Vec3f> {
            const osg::Vec3f bounds = object.ptr().getCellRef().getPrimitiveBounds();
            if (bounds.x() <= 0.f && bounds.y() <= 0.f && bounds.z() <= 0.f)
                return sol::nullopt;
            return bounds;
        };

        // ESM4 NPCs and creatures in the scene, in the object's cell, within radius of position. Trigger volumes look
        // for them here: nearby.actors only lists actors of the base game.
        api["getESM4ActorsNear"] = [context](const Object& object, const osg::Vec3f& position, float radius,
                                       sol::this_state s) -> sol::table {
            sol::state_view lua(s);
            sol::table res(lua, sol::create);
            MWWorld::CellStore* cell = object.ptr().getCell();
            if (cell == nullptr)
                return res;
            const float radius2 = radius * radius;
            int index = 1;
            auto visitor = [&](const MWWorld::Ptr& actor) {
                if (actor.getRefData().getBaseNode() == nullptr || !actor.getRefData().isEnabled())
                    return true;
                if ((actor.getRefData().getPosition().asVec3() - position).length2() > radius2)
                    return true;
                MWBase::Environment::get().getWorldModel()->registerPtr(actor);
                if (context.mType == Context::Global)
                    res[index++] = GObject(actor);
                else
                    res[index++] = LObject(actor);
                return true;
            };
            cell->forEachType<ESM4::Npc>(visitor);
            cell->forEachType<ESM4::Creature>(visitor);
            return res;
        };

        // The world map of a worldspace (WRLD form id): { name, texture (ICON, under textures\), width, height
        // (usable pixels, MNAM), nwCellX, nwCellY, seCellX, seCellY, offsetScale, offsetCellX, offsetCellY (FONV ONAM,
        // nil without) }; nil for an unknown worldspace.
        api["getWorldMap"] = [](std::string_view worldSpaceId, sol::this_state s) -> sol::object {
            const ESM::RefId refId = ESM::RefId::deserializeText(worldSpaceId);
            const ESM4::World* world
                = MWBase::Environment::get().getESMStore()->get<ESM4::World>().search(refId);
            if (world == nullptr)
                return sol::nil;
            sol::state_view lua(s);
            sol::table res(lua, sol::create);
            res["name"] = world->mFullName;
            res["texture"] = world->mMapFile;
            res["width"] = world->mMap.width;
            res["height"] = world->mMap.height;
            res["nwCellX"] = world->mMap.NWcellX;
            res["nwCellY"] = world->mMap.NWcellY;
            res["seCellX"] = world->mMap.SEcellX;
            res["seCellY"] = world->mMap.SEcellY;
            res["parent"] = world->mParent.isZeroOrUnset() ? std::string() : ESM::RefId(world->mParent).serializeText();
            if (world->mMapOffset.present)
            {
                res["offsetScale"] = world->mMapOffset.scale;
                res["offsetCellX"] = world->mMapOffset.cellX;
                res["offsetCellY"] = world->mMapOffset.cellY;
            }
            return res;
        };

        // Map markers (REFR with XMRK) of a worldspace: a list of { id, name, type (TNAM), visible, canTravel,
        // position, rotation (z, radians) }.
        api["getMapMarkers"] = [](std::string_view worldSpaceId, sol::this_state s) {
            sol::state_view lua(s);
            sol::table res(lua, sol::create);
            const ESM::RefId world = ESM::RefId::deserializeText(worldSpaceId);
            const MWWorld::ESMStore& store = *MWBase::Environment::get().getESMStore();
            const MWWorld::Store<ESM4::Reference>& refs = store.get<ESM4::Reference>();
            for (size_t i = 0; i < refs.getSize(); ++i)
            {
                const ESM4::Reference& ref = *refs.at(i);
                if (!ref.mIsMapMarker)
                    continue;
                const ESM4::Cell* cell = store.get<ESM4::Cell>().search(ref.mParent);
                if (cell == nullptr || !cell->isExterior() || cell->mParent != world)
                    continue;
                sol::table t(lua, sol::create);
                t["id"] = ESM::RefId(ref.mId).serializeText();
                t["editorId"] = ref.mEditorId;
                t["name"] = ref.mFullName;
                t["type"] = ref.mMapMarker & 0xff;
                t["visible"] = (ref.mMapMarkerFlags & 0x01) != 0;
                t["canTravel"] = (ref.mMapMarkerFlags & 0x02) != 0;
                t["position"] = ref.mPos.asVec3();
                t["rotation"] = ref.mPos.rot[2];
                res.add(t);
            }
            return res;
        };

        // The local map of the cells around the player (OpenMW's top-down renders): { interior, tiles = { { x, y,
        // texture (a name for ui.texture), width, height } } }. A tile covers one map segment; x grows east, y
        // north. Rendering and registering the textures happen after the Lua frame, so a call returns what the
        // previous one asked for (empty at first). getLocalMap(true) renders the 3x3 cells around the player again.
        struct LocalMapTile
        {
            int mX, mY, mWidth, mHeight;
            std::string mTexture;
        };
        struct LocalMapState
        {
            std::mutex mMutex;
            bool mInterior = false;
            std::vector<LocalMapTile> mTiles;
            int mGeneration = 0;
        };
        static LocalMapState sLocalMap;
        api["getLocalMap"] = [context](sol::this_state s, sol::optional<bool> rerender) -> sol::object {
            context.mLuaManager->addAction(
                [force = rerender.value_or(false)] {
                    MWRender::LocalMap* localMap
                        = MWBase::Environment::get().getWindowManager()->getLocalMapRender();
                    const MWWorld::Ptr player = MWBase::Environment::get().getWorld()->getPlayerPtr();
                    if (localMap == nullptr || player.isEmpty() || player.getCell() == nullptr)
                        return;
                    const MWWorld::CellStore* cell = player.getCell();
                    std::vector<LocalMapTile> tiles;
                    const int generation = ++sLocalMap.mGeneration;
                    auto addTile = [&](int x, int y, bool interior) {
                        osg::ref_ptr<osg::Texture2D> texture = localMap->getMapTexture(x, y);
                        if (!texture)
                            return;
                        const std::string name = "localmap/" + std::string(interior ? "i" : "e") + std::to_string(x)
                            + "_" + std::to_string(y) + "_" + std::to_string(generation % 4);
                        MyGUIPlatform::RenderManager::getInstance().registerExternalTexture(name, texture.get());
                        tiles.push_back({ x, y, texture->getTextureWidth(), texture->getTextureHeight(), name });
                    };
                    if (cell->isExterior())
                    {
                        for (const MWWorld::CellStore* active :
                            MWBase::Environment::get().getWorldScene()->getActiveCells())
                        {
                            if (!active->isExterior()
                                || active->getCell()->getWorldSpace() != cell->getCell()->getWorldSpace())
                                continue;
                            const int dx = active->getCell()->getGridX() - cell->getCell()->getGridX();
                            const int dy = active->getCell()->getGridY() - cell->getCell()->getGridY();
                            if (force && std::abs(dx) <= 1 && std::abs(dy) <= 1)
                                localMap->forceExteriorMap(active);
                            else
                                localMap->requestMap(active);
                            addTile(active->getCell()->getGridX(), active->getCell()->getGridY(), false);
                        }
                    }
                    else
                    {
                        localMap->requestMap(cell);
                        const MyGUI::IntRect grid = localMap->getInteriorGrid();
                        for (int x = grid.left; x <= grid.right; ++x)
                            for (int y = grid.top; y <= grid.bottom; ++y)
                                addTile(x, y, true);
                    }
                    std::lock_guard lock(sLocalMap.mMutex);
                    sLocalMap.mInterior = !cell->isExterior();
                    sLocalMap.mTiles = std::move(tiles);
                },
                "obscriptLocalMapAction");
            sol::state_view lua(s);
            sol::table res(lua, sol::create);
            sol::table tiles(lua, sol::create);
            std::lock_guard lock(sLocalMap.mMutex);
            for (const LocalMapTile& tile : sLocalMap.mTiles)
            {
                sol::table t(lua, sol::create);
                t["x"] = tile.mX;
                t["y"] = tile.mY;
                t["texture"] = tile.mTexture;
                t["width"] = tile.mWidth;
                t["height"] = tile.mHeight;
                tiles.add(t);
            }
            res["interior"] = sLocalMap.mInterior;
            res["tiles"] = tiles;
            return res;
        };

        // Where a world position is on the local map: { x, y (the tile), u, v (0..1 in the tile, v down) }.
        api["localMapPoint"] = [](const osg::Vec3f& position, sol::this_state s) -> sol::object {
            MWRender::LocalMap* localMap = MWBase::Environment::get().getWindowManager()->getLocalMapRender();
            if (localMap == nullptr)
                return sol::nil;
            float u = 0.f;
            float v = 0.f;
            int x = 0;
            int y = 0;
            if (localMap->isInterior())
                localMap->worldToInteriorMapPosition(osg::Vec2f(position.x(), position.y()), u, v, x, y);
            else
            {
                const float size = static_cast<float>(localMap->getMapWorldSize());
                x = static_cast<int>(std::floor(position.x() / size));
                y = static_cast<int>(std::floor(position.y() / size));
                u = (position.x() - size * x) / size;
                v = 1.f - (position.y() - size * y) / size;
            }
            sol::state_view lua(s);
            sol::table res(lua, sol::create);
            res["x"] = x;
            res["y"] = y;
            res["u"] = u;
            res["v"] = v;
            return res;
        };

        // Form id of the reference's linked reference (XLKR), nil when it has none.
        api["getLinkedRef"] = [](const Object& object) -> sol::optional<std::string> {
            const ESM::FormId linked = object.ptr().getCellRef().getLinkedRef();
            if (linked.isZeroOrUnset())
                return sol::nullopt;
            return ESM::RefId(linked).serializeText();
        };

        // Seconds a patrol waits at this reference (XPRD), nil when it is not a patrol point.
        api["getPatrolIdleTime"] = [](const Object& object) -> sol::optional<float> {
            const float time = object.ptr().getCellRef().getPatrolIdleTime();
            if (time < 0.f)
                return sol::nullopt;
            return time;
        };

        // The container a vendor NPC sells from (ACHR XMRC), as a form id; nil when the reference has none.
        api["getMerchantContainer"] = [](const Object& object) -> sol::optional<std::string> {
            const ESM4::ActorCharacter* ref
                = MWBase::Environment::get().getESMStore()->get<ESM4::ActorCharacter>().searchStatic(
                    object.ptr().getCellRef().getRefNum());
            if (ref == nullptr || ref->mMerchantContainer.isZeroOrUnset())
                return sol::nullopt;
            return ESM::RefId(ref->mMerchantContainer).serializeText();
        };

        // What the barter and inventory menus show for an item: { name, value (caps, one item), weight, count,
        // recordId, editorId, icon (texture path under textures\, may be empty), category ('weapon', 'apparel',
        // 'aid', 'ammo' or 'misc') }. Apparel adds { slots (BMDT biped flags), dr, dt, powerArmor, playable }.
        api["itemInfo"] = [](const Object& object, sol::this_state s) -> sol::table {
            sol::state_view lua(s);
            sol::table res(lua, sol::create);
            const MWWorld::Ptr& ptr = object.ptr();
            const MWWorld::Class& cls = ptr.getClass();
            res["name"] = std::string(cls.getName(ptr));
            res["value"] = cls.getValue(ptr);
            res["weight"] = cls.getWeight(ptr);
            res["count"] = ptr.getCellRef().getCount();
            res["recordId"] = ptr.getCellRef().getRefId().serializeText();
            std::string_view category = "misc";
            auto describe = [&](const auto& rec, const std::string& icon) {
                res["editorId"] = rec.mEditorId;
                res["icon"] = icon;
            };
            switch (ptr.getType())
            {
                case ESM::REC_WEAP4:
                    category = "weapon";
                    describe(*ptr.get<ESM4::Weapon>()->mBase, ptr.get<ESM4::Weapon>()->mBase->mIcon);
                    break;
                case ESM::REC_ARMO4:
                {
                    category = "apparel";
                    const ESM4::Armor& armor = *ptr.get<ESM4::Armor>()->mBase;
                    describe(armor, armor.mIconMale.empty() ? armor.mIconFemale : armor.mIconMale);
                    res["slots"] = armor.mArmorFlags;
                    res["dr"] = armor.mDamageResistance;
                    res["dt"] = armor.mDamageThreshold;
                    res["powerArmor"] = (armor.mGeneralFlags & ESM4::Armor::FO3_PowerArmor) != 0;
                    res["playable"] = (armor.mGeneralFlags & ESM4::Armor::FO3_NonPlayable) == 0;
                    break;
                }
                case ESM::REC_CLOT4:
                {
                    category = "apparel";
                    const ESM4::Clothing& clothing = *ptr.get<ESM4::Clothing>()->mBase;
                    describe(clothing, clothing.mIconMale);
                    res["slots"] = clothing.mClothingFlags;
                    res["dr"] = 0;
                    res["dt"] = 0;
                    res["powerArmor"] = false;
                    res["playable"] = true;
                    break;
                }
                case ESM::REC_ALCH4:
                    category = "aid";
                    describe(*ptr.get<ESM4::Potion>()->mBase, ptr.get<ESM4::Potion>()->mBase->mIcon);
                    break;
                case ESM::REC_INGR4:
                    category = "aid";
                    describe(*ptr.get<ESM4::Ingredient>()->mBase, ptr.get<ESM4::Ingredient>()->mBase->mIcon);
                    break;
                case ESM::REC_AMMO4:
                    category = "ammo";
                    describe(*ptr.get<ESM4::Ammunition>()->mBase, ptr.get<ESM4::Ammunition>()->mBase->mIcon);
                    break;
                case ESM::REC_MISC4:
                    describe(*ptr.get<ESM4::MiscItem>()->mBase, ptr.get<ESM4::MiscItem>()->mBase->mIcon);
                    break;
                case ESM::REC_KEYM4:
                    describe(*ptr.get<ESM4::Key>()->mBase, ptr.get<ESM4::Key>()->mBase->mIcon);
                    break;
                case ESM::REC_BOOK4:
                    describe(*ptr.get<ESM4::Book>()->mBase, ptr.get<ESM4::Book>()->mBase->mIcon);
                    // the actor value a skill book teaches, -1 for none
                    res["bookSkill"] = static_cast<int>(ptr.get<ESM4::Book>()->mBase->mData.bookSkill);
                    break;
                default:
                    break;
            }
            res["category"] = category;
            return res;
        };

        // Sequences embedded in the object's model (NiControllerSequences such as "Forward" of a lever or "Open" of a
        // terminal). Group names are lower case. Plays once and holds the last frame.
        api["playEmbeddedGroup"] = [context](const Object& object, std::string_view group) {
            context.mLuaManager->addAction(
                [object = Object(object), group = Misc::StringUtils::lowerCase(group)] {
                    // Some scripts play a group every frame, so report each missing group once.
                    static std::set<std::string> reported;
                    if (!MWClass::ESM4Impl::playEmbeddedAnimation(object.ptr(), group) && reported.insert(group).second)
                        Log(Debug::Verbose)
                            << "[obscript] no embedded animation \"" << group << "\" on " << object.id().toString();
                },
                "obscriptPlayEmbeddedGroupAction");
        };

        // SetOpenState: doors keep their own open state, other objects (terminals, switches, containers) play their
        // "Open" or "Close" sequence.
        api["setOpenState"] = [context](const Object& object, bool open) {
            context.mLuaManager->addAction(
                [object = Object(object), open] {
                    const MWWorld::Ptr& ptr = object.ptr();
                    if (ptr.getType() == ESM4::Door::sRecordId)
                    {
                        if (MWClass::ESM4Door::isOpen(ptr) != open)
                            MWClass::ESM4Door::toggle(ptr);
                        return;
                    }
                    MWClass::ESM4Impl::playEmbeddedAnimation(ptr, open ? "open" : "close");
                },
                "obscriptSetOpenStateAction");
        };

        // Whether a door is open; nil for anything else.
        api["isDoorOpen"] = [](const Object& object) -> sol::optional<bool> {
            const MWWorld::Ptr& ptr = object.ptr();
            if (ptr.getType() != ESM4::Door::sRecordId)
                return sol::nullopt;
            return MWClass::ESM4Door::isOpen(ptr);
        };

        // Blocking message box with buttons (ShowMessage of a MESG with buttons). The pressed
        // button is read with getButtonPressed, which returns it once and -1 otherwise, like
        // GetButtonPressed. UI calls go through actions; the answer arrives a frame later.
        static std::atomic<int> sPressedButton{ -1 };
        api["showMessageBox"] = [context](std::string_view text, sol::table buttons) {
            std::vector<std::string> labels;
            for (size_t i = 1; i <= buttons.size(); ++i)
                labels.push_back(buttons.get<std::string>(i));
            sPressedButton = -1;
            context.mLuaManager->addAction(
                [text = std::string(text), labels = std::move(labels)] {
                    MWBase::Environment::get().getWindowManager()->interactiveMessageBox(text, labels);
                },
                "obscriptShowMessageBoxAction");
        };
        // The FNV message box (scripts/omw/fnvmenus) answers here instead of the Morrowind one: 0 for the first
        // button.
        api["setButtonPressed"] = [](int button) { sPressedButton = button; };
        api["getButtonPressed"] = [context]() -> int {
            context.mLuaManager->addAction(
                [] {
                    const int pressed = MWBase::Environment::get().getWindowManager()->readPressedButton();
                    if (pressed != -1)
                        sPressedButton = pressed;
                },
                "obscriptReadPressedButtonAction");
            return sPressedButton.exchange(-1);
        };

        // The game clock as the FNV globals see it: { hour, day, month, year, daysPassed, timeScale }.
        api["getGameDate"] = [lua]() {
            const MWBase::World* world = MWBase::Environment::get().getWorld();
            sol::table res(lua, sol::create);
            res["hour"] = world->getGlobalFloat(MWWorld::Globals::sGameHour);
            res["day"] = world->getGlobalInt(MWWorld::Globals::sDay);
            res["month"] = world->getGlobalInt(MWWorld::Globals::sMonth);
            res["year"] = world->getGlobalInt(MWWorld::Globals::sYear);
            res["daysPassed"] = world->getGlobalInt(MWWorld::Globals::sDaysPassed);
            res["timeScale"] = world->getGlobalFloat(MWWorld::Globals::sTimeScale);
            return res;
        };
        // Sets one part of the clock: "hour", "day", "month", "year", "daysPassed" or "timeScale".
        api["setGameDate"] = [context](std::string_view part, double value) {
            static const std::map<std::string, MWWorld::GlobalVariableName, std::less<>> names = {
                { "hour", MWWorld::Globals::sGameHour },
                { "day", MWWorld::Globals::sDay },
                { "month", MWWorld::Globals::sMonth },
                { "year", MWWorld::Globals::sYear },
                { "daysPassed", MWWorld::Globals::sDaysPassed },
                { "timeScale", MWWorld::Globals::sTimeScale },
            };
            auto it = names.find(part);
            if (it == names.end())
                throw std::runtime_error("Unknown game date part: " + std::string(part));
            const MWWorld::GlobalVariableName name = it->second;
            context.mLuaManager->addAction(
                [name, value] {
                    MWBase::World* world = MWBase::Environment::get().getWorld();
                    if (world->getGlobalVariableType(name) == 'f')
                        world->setGlobalFloat(name, static_cast<float>(value));
                    else
                        world->setGlobalInt(name, static_cast<int>(value));
                },
                "obscriptSetGameDateAction");
        };

        // Moves the game clock forward by `hours` with day and month rollover (fast travel, waiting).
        api["advanceTime"] = [context](double hours) {
            context.mLuaManager->addAction(
                [hours] { MWBase::Environment::get().getWorld()->advanceTime(hours, false); },
                "obscriptAdvanceTimeAction");
        };

        // Opt-in runtime tracing (OPENMW_OBSCRIPT_TRACE=1); the Lua sandbox has no os.getenv.
        api["traceEnabled"] = [] {
            const char* value = std::getenv("OPENMW_OBSCRIPT_TRACE");
            return value != nullptr && *value != '\0' && std::string_view(value) != "0";
        }();
        // Player input/view trace for soft locks (OPENMW_FNV_UI_TRACE=1, scripts/omw/fnvuitrace.lua).
        api["uiTraceEnabled"] = [] {
            const char* value = std::getenv("OPENMW_FNV_UI_TRACE");
            return value != nullptr && *value != '\0' && std::string_view(value) != "0";
        }();

        api["dialogue"] = initObScriptDialogueBindings(context);
        api["ai"] = initObScriptAIBindings(context);
        api["stats"] = initObScriptStatsBindings(context);
        api["combat"] = initObScriptCombatBindings(context);
        api["physical"] = initObScriptPhysicalBindings(context);
        api["effects"] = initObScriptEffectBindings(context);
        api["radio"] = initObScriptRadioBindings(context);

        return LuaUtil::makeReadOnly(api);
    }
}
