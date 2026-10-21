#include <gmock/gmock.h>
#include <gtest/gtest.h>

#include <filesystem>
#include <fstream>
#include <sstream>

#include <components/lua/luastate.hpp>
#include <components/testing/expecterror.hpp>
#include <components/testing/util.hpp>

namespace
{
    using namespace testing;

    std::string readDataFile(const char* name)
    {
        const auto path = std::filesystem::path{ OPENMW_PROJECT_SOURCE_DIR } / "files" / "data" / name;
        std::ifstream stream(path);
        if (!stream)
            throw std::runtime_error("test data file not found: " + path.string());
        std::stringstream buf;
        buf << stream.rdbuf();
        return buf.str();
    }

    constexpr VFS::Path::NormalizedView runtimePath("openmw_aux/obscript/runtime.lua");
    TestingOpenMW::VFSTestFile runtimeFile(readDataFile("openmw_aux/obscript/runtime.lua"));

    // The driver simulates what transpiled scripts and the engine host do:
    // register handlers, install bindings, read/write variables, fire events.
    constexpr VFS::Path::NormalizedView driverPath("obscript/runtimetests.lua");
    TestingOpenMW::VFSTestFile driverFile(R"X(
        local obs = require('openmw_aux.obscript.runtime')
        return {
            obs = obs,

            loadScript = function(name, handlers)
                -- what a transpiled script does at load time
                local S = obs.locals(name)
                for event, fn in pairs(handlers or {}) do
                    obs.on(event, fn)
                end
                return S
            end,

            truthiness = function()
                return obs.b(0), obs.b(1), obs.b(-2.5), obs.b(nil), obs.b(true)
            end,

            zeroInit = function()
                local S = obs.locals('ZeroInitScript')
                return S.neverSet
            end,

            crossScript = function()
                local S = obs.locals('QuestA')
                S.stage = 7
                return obs.mv('questa', 'stage'), obs.mv('NoSuchScript', 'x')
            end,

            setvRoundTrip = function()
                obs.setv('SomeGlobal', 42)
                return obs.v('someglobal'), obs.v('NeverSetGlobal')
            end,

            msetv = function()
                obs.msetv('QuestB', 'flag', 3)
                return obs.mv('QuestB', 'flag')
            end,

            bindAndDispatch = function()
                local got = nil
                obs.bind('TestCmd', function(a, b) got = { a, b } return 99 end)
                local result = obs.f('testcmd', 'x', 2)
                return result, got[1], got[2]
            end,

            memberDispatchResolvesRef = function()
                obs.resolveRef = function(x) return 'resolved:' .. tostring(x) end
                local seen = nil
                obs.bind('MemberCmd', function(ref) seen = ref return 0 end)
                obs.m('SomeRef', 'MemberCmd')
                obs.resolveRef = function(x) return x end
                return seen
            end,

            unknownCommandIsZero = function()
                local before = obs._unknown['neverimplemented'] or 0
                local value = obs.f('NeverImplemented', 1, 2, 3)
                return value, (obs._unknown['neverimplemented'] or 0) - before
            end,

            fireEvents = function(log)
                obs.locals('FireScript')
                obs.on('OnActivate', function() log[#log + 1] = 'activated' end)
                -- two handlers for one event: both must run, in order
                obs.on('OnActivate', function() log[#log + 1] = 'second' end)
                local hit = obs.fire('firescript', 'onactivate')
                local miss = obs.fire('firescript', 'OnDeath')
                local noScript = obs.fire('NoSuchScript', 'OnActivate')
                return hit, miss, noScript
            end,

            frameRunsGameMode = function(log)
                obs.locals('FrameScript')
                obs.on('GameMode', function() log[#log + 1] = 'tick' end)
                obs.frame()
                obs.frame()
                return #log
            end,

            coverage = function()
                obs.f('CoverageProbeCmd')
                obs.f('CoverageProbeCmd')
                return obs.coverageReport(50)
            end,

            makeLocalScript = function(log)
                obs.locals('LocalIfaceScript')
                obs.on('GameMode', function() log[#log + 1] = 'update' end)
                obs.on('OnActivate', function()
                    log[#log + 1] = 'activated:' .. tostring(obs._actionRef)
                end)
                local script = obs.makeLocalScript()
                local h = script.engineHandlers
                if type(h) ~= 'table' then
                    return 'no engineHandlers'
                end
                h.onUpdate(0.25)
                h.onActivated('someactor')
                local dtSeen = obs._dt
                local save = h.onSave()
                return #log, log[1], log[2], dtSeen, type(save.locals)
            end,

            getActionRef = function()
                -- mirror the bindings.lua definitions
                local playerObj = {}
                local npc = {}
                obs.bind('GetActionRef', function() return obs._actionRef end)
                obs.bind('player', function() return playerObj end)
                obs.locals('ActionRefScript')
                local results = {}
                obs.on('OnActivate', function()
                    -- emitted form of "GetActionRef == player"
                    results[#results + 1] = (obs.v('GetActionRef') == obs.v('player'))
                end)
                local h = obs.makeLocalScript().engineHandlers
                h.onActivated(playerObj)
                h.onActivated(npc)
                return results[1], results[2], obs.v('GetActionRef'),
                    (obs.v('GetActionRef') == obs.v('player'))
            end,

            onLoadDispatch = function(log)
                obs.locals('LoadScript')
                obs.on('OnLoad', function() log[#log + 1] = 'loaded:' .. tostring(obs._actionRef) end)
                local h = obs.makeLocalScript().engineHandlers
                h.onActive()
                h.onActive()
                return #log, log[1]
            end,

            localScriptReadyHook = function()
                local seen = {}
                obs._onLocalScriptReady = function(entry)
                    seen[#seen + 1] = entry.name .. ':' .. tostring(entry.handlers['onactivate'] ~= nil)
                end
                obs.locals('ReadyScriptA')
                obs.on('OnActivate', function() end)
                obs.makeLocalScript()
                obs.locals('ReadyScriptB')
                obs.on('GameMode', function() end)
                obs.makeLocalScript()
                obs._onLocalScriptReady = nil
                return #seen, seen[1], seen[2]
            end,

            triggerBlocks = function(log)
                local actorA = { id = 'a' }
                local actorB = { id = 'b' }
                local inside = {}
                obs._triggerProbe = function() return inside end
                obs.locals('TriggerScript')
                obs.on('OnTriggerEnter', function() log[#log + 1] = 'enter:' .. obs._actionRef.id end)
                obs.on('OnTrigger', function() log[#log + 1] = 'in:' .. obs._actionRef.id end)
                obs.on('OnTriggerLeave', function() log[#log + 1] = 'leave:' .. obs._actionRef.id end)
                local h = obs.makeLocalScript().engineHandlers
                h.onUpdate(0.1)               -- nobody inside
                inside = { actorA }
                h.onUpdate(0.1)               -- A enters
                h.onUpdate(0.1)               -- A stays
                inside = { actorB }
                h.onUpdate(0.1)               -- A leaves, B enters
                inside = {}
                h.onUpdate(0.1)               -- B leaves
                obs._triggerProbe = nil
                return table.concat(log, ',')
            end,

            triggerProbeNotCalledWithoutBlocks = function()
                local calls = 0
                obs._triggerProbe = function() calls = calls + 1 return {} end
                obs.locals('NoTriggerScript')
                obs.on('GameMode', function() end)
                local h = obs.makeLocalScript().engineHandlers
                h.onUpdate(0.1)
                obs._triggerProbe = nil
                return calls
            end,

            makeLocalScriptEmpty = function()
                -- fresh runtime per sandbox in the engine; here simulate by
                -- checking a script with no blocks yields usable handlers
                obs.locals('EmptyIfaceScript')
                local script = obs.makeLocalScript()
                return type(script) == 'table' and 1 or 0
            end,
        }
        )X");

    struct ObScriptRuntimeTest : Test
    {
        std::unique_ptr<VFS::Manager> mVFS = TestingOpenMW::createTestVFS({
            { runtimePath, &runtimeFile },
            { driverPath, &driverFile },
        });

        LuaUtil::ScriptsConfiguration mCfg;
        LuaUtil::LuaState mLua{ mVFS.get(), &mCfg };

        sol::table script()
        {
            const VFS::Path::Normalized path(driverPath);
            return mLua.runInNewSandbox(path);
        }
    };

    TEST_F(ObScriptRuntimeTest, Truthiness)
    {
        sol::table s = script();
        auto r = LuaUtil::call(s["truthiness"]).get<std::tuple<bool, bool, bool, bool, bool>>();
        EXPECT_FALSE(std::get<0>(r)); // 0
        EXPECT_TRUE(std::get<1>(r)); // 1
        EXPECT_TRUE(std::get<2>(r)); // -2.5 (any nonzero number)
        EXPECT_FALSE(std::get<3>(r)); // nil
        EXPECT_TRUE(std::get<4>(r)); // true
    }

    TEST_F(ObScriptRuntimeTest, VariablesZeroInitialized)
    {
        EXPECT_EQ(LuaUtil::call(script()["zeroInit"]).get<int>(), 0);
    }

    TEST_F(ObScriptRuntimeTest, CrossScriptVariables)
    {
        sol::table s = script();
        auto r = LuaUtil::call(s["crossScript"]).get<std::tuple<int, int>>();
        EXPECT_EQ(std::get<0>(r), 7); // case-insensitive script + var lookup
        EXPECT_EQ(std::get<1>(r), 0); // unknown script reads as 0
    }

    TEST_F(ObScriptRuntimeTest, GlobalVariables)
    {
        sol::table s = script();
        auto r = LuaUtil::call(s["setvRoundTrip"]).get<std::tuple<int, int>>();
        EXPECT_EQ(std::get<0>(r), 42);
        EXPECT_EQ(std::get<1>(r), 0); // unknown global reads as 0
        EXPECT_EQ(LuaUtil::call(s["msetv"]).get<int>(), 3);
    }

    TEST_F(ObScriptRuntimeTest, BindAndDispatch)
    {
        sol::table s = script();
        auto r = LuaUtil::call(s["bindAndDispatch"]).get<std::tuple<int, std::string, int>>();
        EXPECT_EQ(std::get<0>(r), 99); // binding return value
        EXPECT_EQ(std::get<1>(r), "x"); // args pass through; name case-insensitive
        EXPECT_EQ(std::get<2>(r), 2);
        EXPECT_EQ(LuaUtil::call(s["memberDispatchResolvesRef"]).get<std::string>(), "resolved:SomeRef");
    }

    TEST_F(ObScriptRuntimeTest, UnknownCommandsStubToZero)
    {
        sol::table s = script();
        auto r = LuaUtil::call(s["unknownCommandIsZero"]).get<std::tuple<int, int>>();
        EXPECT_EQ(std::get<0>(r), 0); // unimplemented command evaluates to 0
        EXPECT_EQ(std::get<1>(r), 1); // and is counted once
    }

    TEST_F(ObScriptRuntimeTest, FireAndFrame)
    {
        sol::table s = script();
        mLua.protectedCall([&](LuaUtil::LuaView& view) {
            sol::table log = view.sol().create_table();
            auto r = LuaUtil::call(s["fireEvents"], log).get<std::tuple<bool, bool, bool>>();
            EXPECT_TRUE(std::get<0>(r)); // event with handlers fires
            EXPECT_FALSE(std::get<1>(r)); // event without handlers
            EXPECT_FALSE(std::get<2>(r)); // unknown script
            ASSERT_EQ(log.size(), 2); // both handlers ran, registration order
            EXPECT_EQ(log[1].get<std::string>(), "activated");
            EXPECT_EQ(log[2].get<std::string>(), "second");

            sol::table frames = view.sol().create_table();
            EXPECT_EQ(LuaUtil::call(s["frameRunsGameMode"], frames).get<int>(), 2);
        });
    }

    TEST_F(ObScriptRuntimeTest, CoverageReport)
    {
        const std::string report = LuaUtil::call(script()["coverage"]).get<std::string>();
        EXPECT_THAT(report, HasSubstr("2  coverageprobecmd"));
    }

    TEST_F(ObScriptRuntimeTest, MakeLocalScript)
    {
        sol::table s = script();
        mLua.protectedCall([&](LuaUtil::LuaView& view) {
            sol::table log = view.sol().create_table();
            auto r = LuaUtil::call(s["makeLocalScript"], log)
                         .get<std::tuple<int, std::string, std::string, double, std::string>>();
            EXPECT_EQ(std::get<0>(r), 2); // both handlers fired
            EXPECT_EQ(std::get<1>(r), "update");
            EXPECT_EQ(std::get<2>(r), "activated:someactor");
            EXPECT_DOUBLE_EQ(std::get<3>(r), 0.25); // dt captured for GetSecondsPassed
            EXPECT_EQ(std::get<4>(r), "table"); // onSave returns serializable locals
        });
    }

    TEST_F(ObScriptRuntimeTest, MakeLocalScriptWithoutBlocks)
    {
        sol::table s = script();
        auto r = LuaUtil::call(s["makeLocalScriptEmpty"]).get<int>();
        EXPECT_EQ(r, 1);
    }

    TEST_F(ObScriptRuntimeTest, OnLoadDispatchedFromOnActive)
    {
        sol::table s = script();
        mLua.protectedCall([&](LuaUtil::LuaView& view) {
            sol::table log = view.sol().create_table();
            auto r = LuaUtil::call(s["onLoadDispatch"], log).get<std::tuple<int, std::string>>();
            EXPECT_EQ(std::get<0>(r), 2); // once per activation of the object
            EXPECT_EQ(std::get<1>(r), "loaded:nil"); // no action ref for OnLoad
        });
    }

    TEST_F(ObScriptRuntimeTest, LocalScriptReadyHookSeesOnActivate)
    {
        sol::table s = script();
        auto r = LuaUtil::call(s["localScriptReadyHook"]).get<std::tuple<int, std::string, std::string>>();
        EXPECT_EQ(std::get<0>(r), 2);
        EXPECT_EQ(std::get<1>(r), "ReadyScriptA:true"); // bindings suppress default activation for this one
        EXPECT_EQ(std::get<2>(r), "ReadyScriptB:false");
    }

    TEST_F(ObScriptRuntimeTest, TriggerBlocks)
    {
        sol::table s = script();
        mLua.protectedCall([&](LuaUtil::LuaView& view) {
            sol::table log = view.sol().create_table();
            const std::string seq = LuaUtil::call(s["triggerBlocks"], log).get<std::string>();
            EXPECT_EQ(seq, "enter:a,in:a,in:a,enter:b,in:b,leave:a,leave:b");
        });
        EXPECT_EQ(LuaUtil::call(s["triggerProbeNotCalledWithoutBlocks"]).get<int>(), 0);
    }

    TEST_F(ObScriptRuntimeTest, GetActionRef)
    {
        sol::table s = script();
        auto r = LuaUtil::call(s["getActionRef"]).get<std::tuple<bool, bool, int, bool>>();
        EXPECT_TRUE(std::get<0>(r)); // player activated: identical object
        EXPECT_FALSE(std::get<1>(r)); // other actor activated
        EXPECT_EQ(std::get<2>(r), 0); // outside activation context
        EXPECT_FALSE(std::get<3>(r)); // 0 does not equal the player object
    }

}
