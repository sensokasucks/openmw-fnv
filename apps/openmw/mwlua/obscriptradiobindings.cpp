#include "obscriptradiobindings.hpp"

#include <algorithm>
#include <cstdio>
#include <map>
#include <mutex>
#include <string>
#include <string_view>

#include <sol/state_view.hpp>
#include <sol/table.hpp>

#include <components/debug/debuglog.hpp>
#include <components/esm/refid.hpp>
#include <components/esm4/loadacti.hpp>
#include <components/esm4/loadaloc.hpp>
#include <components/esm4/loadcell.hpp>
#include <components/esm4/loadinfo.hpp>
#include <components/esm4/loaddial.hpp>
#include <components/esm4/loadmset.hpp>
#include <components/esm4/loadmusc.hpp>
#include <components/esm4/loadqust.hpp>
#include <components/esm4/loadrefr.hpp>
#include <components/esm4/loadsoun.hpp>
#include <components/esm4/loadtact.hpp>
#include <components/esm4/loadvtyp.hpp>
#include <components/esm4/loadwrld.hpp>
#include <components/lua/luastate.hpp>
#include <components/lua/util.hpp>
#include <components/misc/strings/lower.hpp>
#include <components/resource/resourcesystem.hpp>
#include <components/vfs/manager.hpp>
#include <components/vfs/pathutil.hpp>
#include <components/vfs/recursivedirectoryiterator.hpp>

#include "../mwbase/environment.hpp"
#include "../mwbase/soundmanager.hpp"
#include "../mwbase/world.hpp"
#include "../mwsound/ffmpegdecoder.hpp"
#include "../mwworld/cellstore.hpp"
#include "../mwworld/esmstore.hpp"
#include "../mwworld/store.hpp"

#include "context.hpp"
#include "object.hpp"

namespace MWLua
{
    namespace
    {
        std::string formIdText(ESM::FormId id)
        {
            if (id.isZeroOrUnset())
                return {};
            return ESM::RefId(id).serializeText();
        }

        // A record by serialized form id ("FormId:0x...") or editor id (any case).
        template <class T>
        const T* findRecord(std::string_view idOrEditorId)
        {
            const MWWorld::Store<T>& store = MWBase::Environment::get().getESMStore()->template get<T>();
            ESM::RefId refId = ESM::RefId::deserializeText(idOrEditorId);
            if (refId.is<ESM::FormId>())
                if (const T* record = store.search(refId))
                    return record;
            static const std::map<std::string, const T*> byEditorId = [&store] {
                std::map<std::string, const T*> res;
                for (size_t i = 0; i < store.getSize(); ++i)
                {
                    const T* record = store.at(i);
                    if (!record->mEditorId.empty())
                        res.emplace(Misc::StringUtils::lowerCase(record->mEditorId), record);
                }
                return res;
            }();
            auto it = byEditorId.find(Misc::StringUtils::lowerCase(idOrEditorId));
            return it == byEditorId.end() ? nullptr : it->second;
        }

        const VFS::Manager& vfs()
        {
            return *MWBase::Environment::get().getResourceSystem()->getVFS();
        }

        // sound\<file> as the VFS has it (FNV songs are mp3, voices ogg); "" when missing.
        std::string soundFilePath(std::string_view file)
        {
            if (file.empty())
                return {};
            std::string path = Misc::StringUtils::lowerCase("sound\\" + std::string(file));
            if (vfs().exists(VFS::Path::Normalized(path)))
                return path;
            return {};
        }

        // Where a radio reference broadcasts from: the XRDO position reference, or the reference itself.
        const ESM4::Reference* broadcastOrigin(const ESM4::Reference& ref)
        {
            if (ref.mRadio.posReference.isZeroOrUnset())
                return &ref;
            const ESM4::Reference* origin
                = MWBase::Environment::get().getESMStore()->get<ESM4::Reference>().search(ref.mRadio.posReference);
            return origin != nullptr ? origin : &ref;
        }

        void addPlace(sol::table& t, const ESM4::Reference& ref)
        {
            const MWWorld::ESMStore& store = *MWBase::Environment::get().getESMStore();
            const ESM4::Cell* cell = store.get<ESM4::Cell>().search(ref.mParent);
            t["position"] = ref.mPos.asVec3();
            t["cell"] = ref.mParent.serializeText();
            if (cell != nullptr && cell->isExterior())
                t["worldSpace"] = cell->mParent.serializeText();
            else
                t["worldSpace"] = std::string();
            t["interior"] = cell != nullptr && !cell->isExterior();
        }

        void addSoundDistances(sol::table& t, ESM::FormId soundId)
        {
            const ESM4::Sound* sound
                = MWBase::Environment::get().getESMStore()->get<ESM4::Sound>().search(ESM::RefId(soundId));
            if (sound == nullptr)
                return;
            // SNDD/SNDX distances are stored as min / 5 and max / 100 game units
            t["minDistance"] = sound->mData.minAttenuation * 5.f;
            t["maxDistance"] = sound->mData.maxAttenuation * 100.f;
        }

        sol::table makeStation(sol::state_view& lua, const ESM4::Reference& ref, const ESM4::TalkingActivator& base)
        {
            sol::table t(lua, sol::create);
            t["id"] = formIdText(ref.mId);
            t["editorId"] = ref.mEditorId;
            t["base"] = formIdText(base.mId);
            t["baseEditorId"] = base.mEditorId;
            t["name"] = base.mFullName;
            // Non-proxy stations play only from where they stand (casino lounges, the Goodsprings store radio);
            // the others can be tuned in on the Pip-Boy
            t["nonProxy"] = (base.mFlags & ESM4::TACT_NonProxy) != 0;
            t["continuous"] = (base.mFlags & ESM4::TACT_ContBroadcast) != 0;
            t["initiallyDisabled"] = (ref.mFlags & ESM4::Rec_Disabled) != 0;
            // 0 radius, 1 everywhere, 2 worldspace and linked interiors, 3 linked interiors, 4 current cell only
            t["rangeType"] = ref.mRadio.broadcastRange;
            t["radius"] = ref.mRadio.rangeRadius;
            t["staticPercent"] = ref.mRadio.staticPercentage;
            t["voiceType"] = formIdText(base.mVoiceType);
            t["loopSound"] = formIdText(base.mLoopSound);
            t["script"] = formIdText(base.mScriptId);
            addSoundDistances(t, base.mRadioTemplate);
            addPlace(t, ref);
            const ESM4::Reference* origin = broadcastOrigin(ref);
            if (origin != &ref)
            {
                sol::table o(lua, sol::create);
                addPlace(o, *origin);
                t["origin"] = o;
            }
            return t;
        }

        sol::table formList(sol::state_view& lua, const std::vector<ESM::FormId>& ids)
        {
            sol::table res(lua, sol::create);
            for (size_t i = 0; i < ids.size(); ++i)
                res[LuaUtil::toLuaIndex(i)] = formIdText(ids[i]);
            return res;
        }

        std::string voiceFile(const ESM4::DialogInfo& info, int response, ESM::FormId voiceTypeId)
        {
            const MWWorld::ESMStore& store = *MWBase::Environment::get().getESMStore();
            const ESM4::VoiceType* voiceType = store.get<ESM4::VoiceType>().search(ESM::RefId(voiceTypeId));
            const ESM4::Quest* quest = store.get<ESM4::Quest>().search(ESM::RefId(info.mQuest));
            const ESM4::Dialogue* topic = store.get<ESM4::Dialogue>().search(ESM::RefId(info.mTopic));
            if (voiceType == nullptr || quest == nullptr || topic == nullptr || !info.mId.hasContentFile())
                return {};
            const std::vector<std::string>& files = MWBase::Environment::get().getWorld()->getContentFiles();
            if (static_cast<size_t>(info.mId.mContentFile) >= files.size())
                return {};
            char id[16];
            std::snprintf(id, sizeof(id), "%08x", info.mId.mIndex & 0xFFFFFF);
            // the quest and topic editor ids are cut to 10 and 15 characters when together longer than 25
            std::string questName = quest->mEditorId;
            std::string topicName = topic->mEditorId;
            if (questName.size() + topicName.size() > 25)
            {
                questName = questName.substr(0, 10);
                topicName = topicName.substr(0, 15);
            }
            std::string path = "sound\\voice\\" + files[info.mId.mContentFile] + "\\" + voiceType->mEditorId + "\\"
                + questName + "_" + topicName + "_" + id + "_"
                + std::to_string(response) + ".ogg";
            path = Misc::StringUtils::lowerCase(path);
            if (!vfs().exists(VFS::Path::Normalized(path)))
                return {};
            return path;
        }

        std::mutex sDurationMutex;
        std::map<std::string, double> sDurations;
    }

    sol::table initObScriptRadioBindings(const Context& context)
    {
        sol::state_view lua = context.sol();
        sol::table api(lua, sol::create);

        // Radio stations: references to talking activators flagged Radio Station, as
        // { id, editorId, base, baseEditorId, name, nonProxy, continuous, initiallyDisabled, rangeType, radius,
        //   staticPercent, voiceType, loopSound, script, minDistance, maxDistance (the radio template sound's),
        //   position, cell, worldSpace ("" inside), interior, origin (where it broadcasts from, when another
        //   reference: { position, cell, worldSpace, interior }) }.
        api["getStations"] = [](sol::this_state s) {
            sol::state_view lua(s);
            sol::table res(lua, sol::create);
            const MWWorld::ESMStore& store = *MWBase::Environment::get().getESMStore();
            const MWWorld::Store<ESM4::Reference>& refs = store.get<ESM4::Reference>();
            const MWWorld::Store<ESM4::TalkingActivator>& bases = store.get<ESM4::TalkingActivator>();
            for (size_t i = 0; i < refs.getSize(); ++i)
            {
                const ESM4::Reference& ref = *refs.at(i);
                if (!ref.mRadio.present)
                    continue;
                const ESM4::TalkingActivator* base = bases.search(ESM::RefId(ref.mBaseObj));
                if (base == nullptr || (base->mFlags & ESM4::TACT_RadioStation) == 0)
                    continue;
                res.add(makeStation(lua, ref, *base));
            }
            return res;
        };

        // The station (TACT form id) an activator plays when switched on (ACTI RNAM, vintage radios), nil if none.
        api["getActivatorStation"] = [](const Object& object) -> sol::optional<std::string> {
            const MWWorld::Ptr& ptr = object.ptr();
            if (ptr.getType() != ESM::REC_ACTI4)
                return sol::nullopt;
            const ESM4::Activator* base = ptr.get<ESM4::Activator>()->mBase;
            if (base->mRadioStation.isZeroOrUnset())
                return sol::nullopt;
            return formIdText(base->mRadioStation);
        };

        // Sound file of one response (TRDT response number) of an INFO broadcast by a station: the response's
        // own sound (the songs), else the voice file under the station's voice type; nil when neither exists.
        api["getResponseAudio"] = [](std::string_view infoId, int response,
                                      std::string_view voiceTypeId) -> sol::optional<std::string> {
            const MWWorld::ESMStore& store = *MWBase::Environment::get().getESMStore();
            const ESM4::DialogInfo* info
                = store.get<ESM4::DialogInfo>().search(ESM::RefId::deserializeText(infoId));
            if (info == nullptr)
                return sol::nullopt;
            for (const ESM4::DialogResponse& r : info->mResponses)
            {
                if ((r.mData.responseNo & 0xFF) != response || r.mData.sound == 0)
                    continue;
                const ESM4::Sound* sound
                    = store.get<ESM4::Sound>().search(ESM::RefId(ESM::FormId::fromUint32(r.mData.sound)));
                if (sound == nullptr)
                    continue;
                std::string path = soundFilePath(sound->mSoundFile);
                if (!path.empty())
                    return path;
            }
            ESM::FormId voiceType;
            if (const ESM::FormId* id = ESM::RefId::deserializeText(voiceTypeId).getIf<ESM::FormId>())
                voiceType = *id;
            std::string path = voiceFile(*info, response, voiceType);
            if (path.empty())
                return sol::nullopt;
            return path;
        };

        // Length of a sound file in seconds (asks the decoder once per file), nil if it can't be read.
        api["getDuration"] = [](std::string_view file) -> sol::optional<double> {
            const std::string key = Misc::StringUtils::lowerCase(file);
            {
                std::lock_guard lock(sDurationMutex);
                auto it = sDurations.find(key);
                if (it != sDurations.end())
                    return it->second > 0 ? sol::optional<double>(it->second) : sol::nullopt;
            }
            double duration = -1.0;
            try
            {
                MWSound::FFmpegDecoder ffmpeg(&vfs());
                MWSound::SoundDecoder& decoder = ffmpeg;
                decoder.open(VFS::Path::Normalized(key));
                duration = decoder.getDuration();
                decoder.close();
            }
            catch (const std::exception& e)
            {
                Log(Debug::Warning) << "Radio: can't read " << key << ": " << e.what();
            }
            std::lock_guard lock(sDurationMutex);
            sDurations[key] = duration;
            return duration > 0 ? sol::optional<double>(duration) : sol::nullopt;
        };

        // Streams a sound file as the object's speech, `offset` seconds in. The player's plays in 2D (the Pip-Boy
        // radio); others in 3D at the object, with minDistance/maxDistance (<= 0: the voice defaults).
        // Stop it with core.sound.stopSay; core.sound.isSayActive tells when it ended.
        api["say"] = [](const Object& object, std::string_view file, sol::optional<sol::table> options) {
            float offset = 0.f, volume = 1.f, minDistance = 0.f, maxDistance = 0.f;
            if (options)
            {
                offset = options->get_or("offset", 0.f);
                volume = options->get_or("volume", 1.f);
                minDistance = options->get_or("minDistance", 0.f);
                maxDistance = options->get_or("maxDistance", 0.f);
            }
            MWBase::Environment::get().getSoundManager()->sayFrom(
                object.ptr(), VFS::Path::Normalized(file), offset, volume, minDistance, maxDistance);
        };
        api["setVolume"] = [](const Object& object, float volume) {
            MWBase::Environment::get().getSoundManager()->setSayVolume(object.ptr(), volume);
        };

        // Audio markers (REFR with MMRK): { id, controller (ALOC), flags, layer2, layer3, radius, position, cell,
        // worldSpace, interior }.
        api["getAudioMarkers"] = [](sol::this_state s) {
            sol::state_view lua(s);
            sol::table res(lua, sol::create);
            const MWWorld::Store<ESM4::Reference>& refs
                = MWBase::Environment::get().getESMStore()->get<ESM4::Reference>();
            for (size_t i = 0; i < refs.getSize(); ++i)
            {
                const ESM4::Reference& ref = *refs.at(i);
                if (!ref.mIsAudioMarker)
                    continue;
                sol::table t(lua, sol::create);
                t["id"] = formIdText(ref.mId);
                t["controller"] = formIdText(ref.mAudioLocation);
                t["flags"] = ref.mAudioMarkerFlags;
                t["layer2"] = ref.mAudioLayer2;
                t["layer3"] = ref.mAudioLayer3;
                t["radius"] = ref.mRadius;
                t["initiallyDisabled"] = (ref.mFlags & ESM4::Rec_Disabled) != 0;
                addPlace(t, ref);
                res.add(t);
            }
            return res;
        };

        // Media location controller (ALOC): { id, editorId, locationSets, battleSets, enemySets, neutralSets,
        // friendSets, allySets (MSET form ids), looping (0 loop, 1 random, 2 retrigger, 3 none; 4..7 the same with
        // the default day/night hours), factionNotFound, conditionalFaction, locationDelay, retriggerDelay,
        // dayStart, nightStart }.
        api["getMediaLocation"] = [](std::string_view id, sol::this_state s) -> sol::object {
            const ESM4::MediaLocationController* c = findRecord<ESM4::MediaLocationController>(id);
            if (c == nullptr)
                return sol::nil;
            sol::state_view lua(s);
            sol::table t(lua, sol::create);
            t["id"] = formIdText(c->mId);
            t["editorId"] = c->mEditorId;
            t["locationSets"] = formList(lua, c->mLocationSets);
            t["battleSets"] = formList(lua, c->mBattleSets);
            t["enemySets"] = formList(lua, c->mEnemySets);
            t["neutralSets"] = formList(lua, c->mNeutralSets);
            t["friendSets"] = formList(lua, c->mFriendSets);
            t["allySets"] = formList(lua, c->mAllySets);
            t["looping"] = c->mMediaFlags.loopingOptions;
            t["factionNotFound"] = c->mMediaFlags.factionNotFound;
            t["conditionalFaction"] = formIdText(c->mConditionalFaction);
            t["locationDelay"] = c->mLocationDelay;
            t["retriggerDelay"] = c->mRetriggerDelay;
            t["dayStart"] = c->mDayStart;
            t["nightStart"] = c->mNightStart;
            return t;
        };

        // Media set (MSET): { id, editorId, type (0 battle, 1 location, 2 dungeon, 3 incidental), enabled (location
        // layer bits), files = { [2..7] = music\ path } (location: day outer, middle, inner, night outer, middle,
        // inner; battle: [2] the loop), boundaries = { day outer, middle, inner, night outer, middle, inner } (%),
        // levels (dB), intro, outro (SOUN form ids), fade (DNAM, s) }.
        api["getMediaSet"] = [](std::string_view id, sol::this_state s) -> sol::object {
            const ESM4::MediaSet* m = findRecord<ESM4::MediaSet>(id);
            if (m == nullptr)
                return sol::nil;
            sol::state_view lua(s);
            sol::table t(lua, sol::create);
            t["id"] = formIdText(m->mId);
            t["editorId"] = m->mEditorId;
            t["type"] = m->mSetType;
            t["enabled"] = m->mEnabled;
            sol::table files(lua, sol::create);
            const std::string* sets[] = { &m->mSet2, &m->mSet3, &m->mSet4, &m->mSet5, &m->mSet6, &m->mSet7 };
            for (int i = 0; i < 6; ++i)
                if (!sets[i]->empty())
                    files[i + 2] = Misc::StringUtils::lowerCase("music\\" + *sets[i]);
            t["files"] = files;
            sol::table boundaries(lua, sol::create);
            const float b[] = { m->mBoundaryDayOuter, m->mBoundaryDayMiddle, m->mBoundaryDayInner,
                m->mBoundaryNightOuter, m->mBoundaryNightMiddle, m->mBoundaryNightInner };
            for (int i = 0; i < 6; ++i)
                boundaries[i + 1] = b[i];
            t["boundaries"] = boundaries;
            sol::table levels(lua, sol::create);
            const float l[] = { m->mLevel8, m->mLevel9, m->mLevel0, m->mLevelA, m->mLevelB, m->mLevelC };
            for (int i = 0; i < 6; ++i)
                levels[i + 1] = l[i];
            t["levels"] = levels;
            t["intro"] = formIdText(m->mSoundIntro);
            t["outro"] = formIdText(m->mSoundOutro);
            t["fade"] = m->mTime1;
            return t;
        };

        // Music type (MUSC) by form id or editor id: { id, editorId, file (music\ path; a folder ends with \),
        // attenuation (dB) }.
        api["getMusic"] = [](std::string_view id, sol::this_state s) -> sol::object {
            const ESM4::Music* m = findRecord<ESM4::Music>(id);
            if (m == nullptr)
                return sol::nil;
            sol::state_view lua(s);
            sol::table t(lua, sol::create);
            t["id"] = formIdText(m->mId);
            t["editorId"] = m->mEditorId;
            t["file"] = m->mMusicFile.empty() ? std::string()
                                              : Misc::StringUtils::lowerCase("music\\" + m->mMusicFile);
            t["attenuation"] = m->mAttenuation;
            return t;
        };

        // Sound files (mp3, ogg, wav) in a VFS folder such as "music\\special", sorted.
        api["listSoundFiles"] = [](std::string_view folder, sol::this_state s) {
            sol::state_view lua(s);
            sol::table res(lua, sol::create);
            std::vector<std::string> files;
            const VFS::Path::Normalized dir(folder);
            for (const VFS::Path::Normalized& file : vfs().getRecursiveDirectoryIterator(VFS::Path::NormalizedView(dir)))
            {
                const std::string_view v = file.view();
                if (v.ends_with(".mp3") || v.ends_with(".ogg") || v.ends_with(".wav"))
                    files.emplace_back(v);
            }
            std::sort(files.begin(), files.end());
            for (size_t i = 0; i < files.size(); ++i)
                res[LuaUtil::toLuaIndex(i)] = files[i];
            return res;
        };

        // The music an object's cell asks for: { cellMusic (MUSC form id, CELL XCMO), worldMusic (WRLD ZNAM),
        // cell, worldSpace, interior }.
        api["getCellMusic"] = [](const Object& object, sol::this_state s) -> sol::object {
            const MWWorld::Ptr& ptr = object.ptr();
            if (ptr.getCell() == nullptr)
                return sol::nil;
            const MWWorld::ESMStore& store = *MWBase::Environment::get().getESMStore();
            const ESM::RefId cellId = ptr.getCell()->getCell()->getId();
            const ESM4::Cell* cell = store.get<ESM4::Cell>().search(cellId);
            if (cell == nullptr)
                return sol::nil;
            sol::state_view lua(s);
            sol::table t(lua, sol::create);
            t["cellMusic"] = formIdText(cell->mMusic);
            t["cell"] = cellId.serializeText();
            t["interior"] = !cell->isExterior();
            if (cell->isExterior())
            {
                t["worldSpace"] = cell->mParent.serializeText();
                if (const ESM4::World* world = store.get<ESM4::World>().search(cell->mParent))
                    t["worldMusic"] = formIdText(world->mMusic);
            }
            else
                t["worldSpace"] = std::string();
            return t;
        };

        return LuaUtil::makeReadOnly(api);
    }
}
