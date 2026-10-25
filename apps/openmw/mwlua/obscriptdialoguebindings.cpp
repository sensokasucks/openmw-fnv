#include "obscriptdialoguebindings.hpp"

#include <algorithm>
#include <map>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

#include <sol/state_view.hpp>
#include <sol/table.hpp>

#include <components/esm/refid.hpp>
#include <components/esm4/dialogue.hpp>
#include <components/esm4/loadcrea.hpp>
#include <components/esm4/loaddial.hpp>
#include <components/esm4/loadglob.hpp>
#include <components/esm4/loadinfo.hpp>
#include <components/esm4/loadnpc.hpp>
#include <components/esm4/loadqust.hpp>
#include <components/esm4/loadscpt.hpp>
#include <components/lua/luastate.hpp>
#include <components/lua/util.hpp>
#include <components/misc/strings/lower.hpp>

#include "../mwbase/environment.hpp"
#include "../mwclass/esm4npc.hpp"
#include "../mwworld/cellref.hpp"
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

        ESM::FormId parseFormId(std::string_view text)
        {
            ESM::RefId refId = ESM::RefId::deserializeText(text);
            if (const ESM::FormId* formId = refId.getIf<ESM::FormId>())
                return *formId;
            return {};
        }

        // Lookup tables over the dialogue records, built on first use (the
        // record stores do not change after the content files are loaded).
        struct DialogueIndex
        {
            std::map<std::string, ESM::FormId> mTopicsByEditorId; // lower-case editor id
            std::map<std::string, ESM::FormId> mQuestsByEditorId;
            std::map<std::string, ESM::FormId> mGlobalsByEditorId;
            std::map<ESM::FormId, std::vector<const ESM4::DialogInfo*>> mInfosByTopic; // sorted, see below
            std::vector<const ESM4::Dialogue*> mTopLevelTopics; // sorted by priority, then name

            DialogueIndex()
            {
                const MWWorld::ESMStore& store = *MWBase::Environment::get().getESMStore();

                const MWWorld::Store<ESM4::Dialogue>& topics = store.get<ESM4::Dialogue>();
                for (size_t i = 0; i < topics.getSize(); ++i)
                {
                    const ESM4::Dialogue& topic = *topics.at(i);
                    if (!topic.mEditorId.empty())
                        mTopicsByEditorId.emplace(Misc::StringUtils::lowerCase(topic.mEditorId), topic.mId);
                    // FO3/FONV: 0x02 marks a top-level topic (always offered when it has a valid INFO)
                    if (topic.mDialType == ESM4::DTYP_Topic && (topic.mDialFlags & 0x02) != 0)
                        mTopLevelTopics.push_back(&topic);
                }
                std::sort(mTopLevelTopics.begin(), mTopLevelTopics.end(),
                    [](const ESM4::Dialogue* a, const ESM4::Dialogue* b) {
                        if (a->mPriority != b->mPriority)
                            return a->mPriority > b->mPriority;
                        return a->mTopicName < b->mTopicName;
                    });

                const MWWorld::Store<ESM4::Quest>& quests = store.get<ESM4::Quest>();
                for (size_t i = 0; i < quests.getSize(); ++i)
                {
                    const ESM4::Quest& quest = *quests.at(i);
                    if (!quest.mEditorId.empty())
                        mQuestsByEditorId.emplace(Misc::StringUtils::lowerCase(quest.mEditorId), quest.mId);
                }

                const MWWorld::Store<ESM4::GlobalVariable>& globals = store.get<ESM4::GlobalVariable>();
                for (size_t i = 0; i < globals.getSize(); ++i)
                {
                    const ESM4::GlobalVariable& global = *globals.at(i);
                    if (!global.mEditorId.empty())
                        mGlobalsByEditorId.emplace(Misc::StringUtils::lowerCase(global.mEditorId), global.mId);
                }

                const MWWorld::Store<ESM4::DialogInfo>& infos = store.get<ESM4::DialogInfo>();
                for (size_t i = 0; i < infos.getSize(); ++i)
                {
                    const ESM4::DialogInfo& info = *infos.at(i);
                    mInfosByTopic[info.mTopic].push_back(&info);
                }
                // The engine picks the first INFO whose conditions pass. INFOs of
                // higher-priority quests are checked first; within a quest the
                // order is the order in the content file.
                auto questPriority = [&](ESM::FormId questId) -> int {
                    const ESM4::Quest* quest = quests.search(ESM::RefId(questId));
                    return quest ? quest->mData.priority : 0;
                };
                for (auto& [topicId, list] : mInfosByTopic)
                {
                    std::stable_sort(
                        list.begin(), list.end(), [&](const ESM4::DialogInfo* a, const ESM4::DialogInfo* b) {
                            const int pa = questPriority(a->mQuest);
                            const int pb = questPriority(b->mQuest);
                            if (pa != pb)
                                return pa > pb;
                            return a->mLoadIndex < b->mLoadIndex;
                        });
                }
            }
        };

        const DialogueIndex& getIndex()
        {
            static const std::unique_ptr<DialogueIndex> index = std::make_unique<DialogueIndex>();
            return *index;
        }

        ESM::FormId resolve(const std::map<std::string, ESM::FormId>& byEditorId, std::string_view idOrEditorId)
        {
            auto it = byEditorId.find(Misc::StringUtils::lowerCase(idOrEditorId));
            if (it != byEditorId.end())
                return it->second;
            return parseFormId(idOrEditorId);
        }

        bool isOrCombined(const std::vector<ESM4::DialogCondition>& conditions, size_t i)
        {
            if (conditions[i].mData.condition & ESM4::CTF_Combine)
                return true;
            return i > 0 && (conditions[i - 1].mData.condition & ESM4::CTF_Combine);
        }

        // Cheap pre-filter: false when a mandatory `GetIsID X == 1` on the
        // subject names another actor. Everything else is left to Lua.
        bool mayBeSpokenBy(const ESM4::DialogInfo& info, ESM::FormId speaker)
        {
            if (speaker.isZeroOrUnset())
                return true;
            for (size_t i = 0; i < info.mConditions.size(); ++i)
            {
                const ESM4::DialogCondition& cond = info.mConditions[i];
                if (cond.mData.functionIndex != ESM4::FUN_GetIsID || cond.mData.runOn != 0
                    || (cond.mData.condition & (ESM4::CTF_UseGlobal | ESM4::CTF_RunOnTarget)) != 0
                    || isOrCombined(info.mConditions, i))
                    continue;
                const std::uint32_t op = cond.mData.condition & 0xE0;
                const bool mustBe = (op == ESM4::CTF_EqualTo && cond.mData.comparison == 1.f)
                    || (op == ESM4::CTF_NotEqualTo && cond.mData.comparison == 0.f);
                if (mustBe && cond.mParam1 != speaker)
                    return false;
            }
            return true;
        }

        std::string_view operatorName(std::uint32_t condition)
        {
            switch (condition & 0xE0)
            {
                case ESM4::CTF_EqualTo:
                    return "==";
                case ESM4::CTF_NotEqualTo:
                    return "~=";
                case ESM4::CTF_GreaterThan:
                    return ">";
                case ESM4::CTF_GrThOrEqTo:
                    return ">=";
                case ESM4::CTF_LessThan:
                    return "<";
                case ESM4::CTF_LeThOrEqTo:
                    return "<=";
            }
            return "==";
        }

        sol::table makeConditions(sol::state_view& lua, const std::vector<ESM4::DialogCondition>& conditions)
        {
            sol::table res(lua, sol::create);
            for (size_t i = 0; i < conditions.size(); ++i)
            {
                const ESM4::DialogCondition& cond = conditions[i];
                sol::table c(lua, sol::create);
                c["func"] = cond.mData.functionIndex & 0xFFFF;
                c["op"] = operatorName(cond.mData.condition);
                c["isOr"] = (cond.mData.condition & ESM4::CTF_Combine) != 0;
                c["runOn"] = (cond.mData.condition & ESM4::CTF_RunOnTarget) != 0 ? 1 : cond.mData.runOn;
                if (cond.mData.condition & ESM4::CTF_UseGlobal)
                    c["global"] = formIdText(cond.mGlobal);
                else
                    c["value"] = cond.mData.comparison;
                c["param1"] = cond.mData.param1;
                c["param2"] = cond.mData.param2;
                c["param1Form"] = formIdText(cond.mParam1);
                c["param2Form"] = formIdText(cond.mParam2);
                c["reference"] = formIdText(cond.mReference);
                res[LuaUtil::toLuaIndex(i)] = c;
            }
            return res;
        }

        sol::table makeFormList(sol::state_view& lua, const std::vector<ESM::FormId>& ids)
        {
            sol::table res(lua, sol::create);
            for (size_t i = 0; i < ids.size(); ++i)
                res[LuaUtil::toLuaIndex(i)] = formIdText(ids[i]);
            return res;
        }

        sol::table makeInfo(sol::state_view& lua, const ESM4::DialogInfo& info)
        {
            sol::table res(lua, sol::create);
            res["id"] = formIdText(info.mId);
            res["topic"] = formIdText(info.mTopic);
            res["quest"] = formIdText(info.mQuest);
            res["speaker"] = formIdText(info.mSpeaker);
            res["flags"] = info.mInfoFlags;
            res["dialType"] = info.mDialType;
            res["prompt"] = info.mPrompt;
            sol::table responses(lua, sol::create);
            for (size_t i = 0; i < info.mResponses.size(); ++i)
            {
                const ESM4::DialogResponse& response = info.mResponses[i];
                sol::table r(lua, sol::create);
                r["text"] = response.mText;
                r["notes"] = response.mNotes;
                r["emotion"] = response.mData.emoType;
                r["emotionValue"] = response.mData.emoValue;
                r["number"] = response.mData.responseNo & 0xFF;
                r["sound"] = formIdText(ESM::FormId::fromUint32(response.mData.sound));
                responses[LuaUtil::toLuaIndex(i)] = r;
            }
            res["responses"] = responses;
            res["conditions"] = makeConditions(lua, info.mConditions);
            res["scriptBegin"] = info.mScript.scriptSource;
            res["scriptEnd"] = info.mScriptEnd.scriptSource;
            res["choices"] = makeFormList(lua, info.mChoices);
            res["linkFrom"] = makeFormList(lua, info.mLinkFrom);
            res["addTopics"] = makeFormList(lua, info.mAddTopics);
            return res;
        }

        sol::table makeTopic(sol::state_view& lua, const ESM4::Dialogue& topic)
        {
            sol::table res(lua, sol::create);
            res["id"] = formIdText(topic.mId);
            res["editorId"] = topic.mEditorId;
            res["name"] = topic.mTopicName;
            res["type"] = topic.mDialType;
            res["flags"] = topic.mDialFlags;
            res["priority"] = topic.mPriority;
            res["isTopLevel"] = topic.mDialType == ESM4::DTYP_Topic && (topic.mDialFlags & 0x02) != 0;
            res["quests"] = makeFormList(lua, topic.mQuests);
            return res;
        }

        // Variable index -> name, for GetQuestVariable/GetScriptVariable conditions.
        sol::table makeScriptVariables(sol::state_view& lua, ESM::FormId scriptId)
        {
            sol::table res(lua, sol::create);
            const ESM4::Script* script
                = MWBase::Environment::get().getESMStore()->get<ESM4::Script>().search(ESM::RefId(scriptId));
            if (script == nullptr)
                return res;
            for (const ESM4::ScriptLocalVariableData& var : script->mScript.localVarData)
                res[var.index] = var.variableName;
            return res;
        }

        sol::table makeQuest(sol::state_view& lua, const ESM4::Quest& quest)
        {
            sol::table res(lua, sol::create);
            res["id"] = formIdText(quest.mId);
            res["editorId"] = quest.mEditorId;
            res["name"] = quest.mQuestName;
            res["flags"] = quest.mData.flags;
            res["priority"] = quest.mData.priority;
            res["startGameEnabled"] = (quest.mData.flags & ESM4::Quest::Flag_StartGameEnabled) != 0;
            res["allowRepeatedStages"] = (quest.mData.flags & ESM4::Quest::Flag_AllowRepeatStages) != 0;
            res["delay"] = quest.mData.questDelay; // seconds between script runs; 0 = fQuestScriptDelayTime
            sol::table objectives(lua, sol::create);
            for (size_t i = 0; i < quest.mObjectives.size(); ++i)
            {
                sol::table o(lua, sol::create);
                o["index"] = quest.mObjectives[i].mIndex;
                o["text"] = quest.mObjectives[i].mText;
                objectives[LuaUtil::toLuaIndex(i)] = o;
            }
            res["objectives"] = objectives;
            res["script"] = formIdText(quest.mQuestScript);
            res["variables"] = makeScriptVariables(lua, quest.mQuestScript);
            sol::table stages(lua, sol::create);
            for (size_t i = 0; i < quest.mStages.size(); ++i)
            {
                const ESM4::QuestStage& stage = quest.mStages[i];
                sol::table s(lua, sol::create);
                s["index"] = stage.mIndex;
                sol::table entries(lua, sol::create);
                for (size_t j = 0; j < stage.mEntries.size(); ++j)
                {
                    const ESM4::QuestLogEntry& entry = stage.mEntries[j];
                    sol::table e(lua, sol::create);
                    e["flags"] = entry.mFlags;
                    e["log"] = entry.mLogText;
                    e["script"] = entry.mScript.scriptSource;
                    e["conditions"] = makeConditions(lua, entry.mConditions);
                    entries[LuaUtil::toLuaIndex(j)] = e;
                }
                s["entries"] = entries;
                stages[LuaUtil::toLuaIndex(i)] = s;
            }
            res["stages"] = stages;
            return res;
        }
    }

    sol::table makeObScriptConditions(sol::state_view& lua, const std::vector<ESM4::DialogCondition>& conditions)
    {
        return makeConditions(lua, conditions);
    }

    sol::table initObScriptDialogueBindings(const Context& context)
    {
        sol::state_view lua = context.sol();
        sol::table api(lua, sol::create);

        // Topic (DIAL) by form id or editor id; nil if unknown.
        api["getTopic"] = [](std::string_view idOrEditorId, sol::this_state s) -> sol::object {
            sol::state_view lua(s);
            const ESM::FormId id = resolve(getIndex().mTopicsByEditorId, idOrEditorId);
            const ESM4::Dialogue* topic
                = MWBase::Environment::get().getESMStore()->get<ESM4::Dialogue>().search(ESM::RefId(id));
            if (topic == nullptr)
                return sol::nil;
            return makeTopic(lua, *topic);
        };

        // INFOs of a topic in evaluation order. With a speaker record id, INFOs
        // that require another actor (GetIsID) are left out.
        api["getTopicInfos"]
            = [](std::string_view topicId, sol::optional<std::string_view> speaker, sol::this_state s) -> sol::table {
            sol::state_view lua(s);
            sol::table res(lua, sol::create);
            const DialogueIndex& index = getIndex();
            const ESM::FormId id = resolve(index.mTopicsByEditorId, topicId);
            auto it = index.mInfosByTopic.find(id);
            if (it == index.mInfosByTopic.end())
                return res;
            const ESM::FormId speakerId = speaker ? parseFormId(*speaker) : ESM::FormId();
            size_t n = 0;
            for (const ESM4::DialogInfo* info : it->second)
                if (mayBeSpokenBy(*info, speakerId))
                    res[LuaUtil::toLuaIndex(n++)] = makeInfo(lua, *info);
            return res;
        };

        // Top-level topics that have at least one INFO this speaker may say.
        api["getSpeakerTopics"] = [](std::string_view speaker, sol::this_state s) -> sol::table {
            sol::state_view lua(s);
            sol::table res(lua, sol::create);
            const DialogueIndex& index = getIndex();
            const ESM::FormId speakerId = parseFormId(speaker);
            size_t n = 0;
            for (const ESM4::Dialogue* topic : index.mTopLevelTopics)
            {
                auto it = index.mInfosByTopic.find(topic->mId);
                if (it == index.mInfosByTopic.end())
                    continue;
                for (const ESM4::DialogInfo* info : it->second)
                {
                    if (mayBeSpokenBy(*info, speakerId))
                    {
                        res[LuaUtil::toLuaIndex(n++)] = formIdText(topic->mId);
                        break;
                    }
                }
            }
            return res;
        };

        // Quest (QUST) by form id or editor id; nil if unknown.
        api["getQuest"] = [](std::string_view idOrEditorId, sol::this_state s) -> sol::object {
            sol::state_view lua(s);
            const ESM::FormId id = resolve(getIndex().mQuestsByEditorId, idOrEditorId);
            const ESM4::Quest* quest
                = MWBase::Environment::get().getESMStore()->get<ESM4::Quest>().search(ESM::RefId(id));
            if (quest == nullptr)
                return sol::nil;
            return makeQuest(lua, *quest);
        };

        // Form ids of all quests.
        api["getAllQuests"] = [](sol::this_state s) -> sol::table {
            sol::state_view lua(s);
            sol::table res(lua, sol::create);
            const MWWorld::Store<ESM4::Quest>& quests = MWBase::Environment::get().getESMStore()->get<ESM4::Quest>();
            for (size_t i = 0; i < quests.getSize(); ++i)
                res[LuaUtil::toLuaIndex(i)] = formIdText(quests.at(i)->mId);
            return res;
        };

        // Form ids of the quests flagged "start game enabled".
        api["getStartGameEnabledQuests"] = [](sol::this_state s) -> sol::table {
            sol::state_view lua(s);
            sol::table res(lua, sol::create);
            const MWWorld::Store<ESM4::Quest>& quests = MWBase::Environment::get().getESMStore()->get<ESM4::Quest>();
            size_t n = 0;
            for (size_t i = 0; i < quests.getSize(); ++i)
            {
                const ESM4::Quest& quest = *quests.at(i);
                if (quest.mData.flags & ESM4::Quest::Flag_StartGameEnabled)
                    res[LuaUtil::toLuaIndex(n++)] = formIdText(quest.mId);
            }
            return res;
        };

        // Global variable (GLOB) by form id or editor id: { id, editorId, value } or nil.
        api["getGlobal"] = [](std::string_view idOrEditorId, sol::this_state s) -> sol::object {
            sol::state_view lua(s);
            const ESM::FormId id = resolve(getIndex().mGlobalsByEditorId, idOrEditorId);
            const ESM4::GlobalVariable* global
                = MWBase::Environment::get().getESMStore()->get<ESM4::GlobalVariable>().search(ESM::RefId(id));
            if (global == nullptr)
                return sol::nil;
            sol::table res(lua, sol::create);
            res["id"] = formIdText(global->mId);
            res["editorId"] = global->mEditorId;
            res["value"] = global->mValue;
            return res;
        };

        // Dialogue-relevant data of an ESM4 NPC reference, nil for anything else.
        api["getActor"] = [](const Object& object, sol::this_state s) -> sol::object {
            sol::state_view lua(s);
            const MWWorld::Ptr& ptr = object.ptr();
            if (ptr.getType() != ESM::REC_NPC_4)
                return sol::nil;
            const ESM4::Npc* base = ptr.get<ESM4::Npc>()->mBase;
            const ESM4::Npc* traits = MWClass::ESM4Npc::getTraitsRecord(ptr);
            if (traits == nullptr)
                traits = base;
            sol::table res(lua, sol::create);
            res["recordId"] = formIdText(base->mId);
            res["reference"] = formIdText(ptr.getCellRef().getRefNum());
            res["editorId"] = base->mEditorId;
            res["name"] = traits->mFullName.empty() ? base->mFullName : traits->mFullName;
            res["race"] = formIdText(traits->mRace);
            res["class"] = formIdText(traits->mClass);
            res["faction"] = formIdText(ESM::FormId::fromUint32(base->mFaction.faction));
            res["factionRank"] = base->mFaction.rank;
            res["isFemale"] = MWClass::ESM4Npc::isFemale(ptr);
            res["script"] = formIdText(base->mScriptId);
            res["voiceType"] = formIdText(base->mVoiceType);
            return res;
        };

        // Voice type (VTCK) of an ESM4 NPC or creature reference, "" when it has none.
        api["getVoiceType"] = [](const Object& object) -> std::string {
            const MWWorld::Ptr& ptr = object.ptr();
            if (ptr.getType() == ESM::REC_NPC_4)
                return formIdText(ptr.get<ESM4::Npc>()->mBase->mVoiceType);
            if (ptr.getType() == ESM::REC_CREA4)
                return formIdText(ptr.get<ESM4::Creature>()->mBase->mVoiceType);
            return {};
        };

        // Script (SCPT) by form id or editor id: { id, editorId, type, enabled, source } or nil.
        // type: 0 object, 1 quest, 0x100 effect.
        api["getScript"] = [](std::string_view idOrEditorId, sol::this_state s) -> sol::object {
            sol::state_view lua(s);
            const MWWorld::Store<ESM4::Script>& scripts = MWBase::Environment::get().getESMStore()->get<ESM4::Script>();
            const ESM4::Script* script = scripts.search(ESM::RefId(parseFormId(idOrEditorId)));
            if (script == nullptr)
            {
                static const std::map<std::string, const ESM4::Script*> byEditorId = [&scripts] {
                    std::map<std::string, const ESM4::Script*> res;
                    for (size_t i = 0; i < scripts.getSize(); ++i)
                        res.emplace(Misc::StringUtils::lowerCase(scripts.at(i)->mEditorId), scripts.at(i));
                    return res;
                }();
                auto it = byEditorId.find(Misc::StringUtils::lowerCase(idOrEditorId));
                if (it == byEditorId.end())
                    return sol::nil;
                script = it->second;
            }
            sol::table res(lua, sol::create);
            res["id"] = formIdText(script->mId);
            res["editorId"] = script->mEditorId;
            res["type"] = script->mScript.scriptHeader.type;
            res["enabled"] = (script->mScript.scriptHeader.flag & 0x01) != 0;
            res["source"] = script->mScript.scriptSource;
            return res;
        };

        // Form id of a placed reference (REFR/ACHR), for GetIsReference.
        api["getReferenceId"]
            = [](const Object& object) -> std::string { return formIdText(object.ptr().getCellRef().getRefNum()); };

        // Variable index -> name for a SCPT record (GetQuestVariable/GetScriptVariable).
        api["getScriptVariables"] = [](std::string_view scriptId, sol::this_state s) -> sol::table {
            sol::state_view lua(s);
            return makeScriptVariables(lua, parseFormId(scriptId));
        };

        return LuaUtil::makeReadOnly(api);
    }
}
