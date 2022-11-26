% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(couch_quickjs_scanner_plugin_tests).

-include_lib("couch/include/couch_eunit.hrl").
-include_lib("couch/include/couch_db.hrl").

couch_quickjs_scanner_plugin_test_() ->
    {
        foreach,
        fun setup/0,
        fun teardown/1,
        [
            ?TDEF_FE(t_basic, 10)
        ]
    }.

-define(DOC1, <<"doc1">>).
-define(DOC2, <<"doc2">>).
-define(DOC3, <<"doc3">>).
-define(DOC4, <<"doc4">>).
-define(DOC5, <<"doc5">>).
-define(DDOC1, <<"_design/ddoc1">>).

-define(PLUGIN, couch_quickjs_scanner_plugin).

setup() ->
    {module, _} = code:ensure_loaded(?PLUGIN),
    meck:new(?PLUGIN, [passthrough]),
    meck:new(couch_scanner_server, [passthrough]),
    meck:new(couch_scanner_util, [passthrough]),
    Ctx = test_util:start_couch([fabric, couch_scanner]),
    DbName = ?tempdb(),
    ok = fabric:create_db(DbName, [{q, "2"}, {n, "1"}]),
    ok = add_doc(DbName, ?DOC1, #{a => x}),
    ok = add_doc(DbName, ?DOC2, #{a => y}),
    ok = add_doc(DbName, ?DOC3, #{a => z}),
    ok = add_doc(DbName, ?DOC4, #{a => w}),
    ok = add_doc(DbName, ?DOC5, #{a => u}),
    ok = add_doc(DbName, ?DDOC1, #{
        views => #{
            v => #{
                map => <<
                    "function(doc) {\n"
                    "  if(doc.a == 'x') {\n"
                    "    r = doc.a.search(/(x+)/); emit(r, RegExp.$1)\n"
                    "  } else {\n"
                    "    emit(doc.a, doc.a);\n"
                    "  }\n"
                    "}"
                >>,
                reduce => <<
                    "function(ks, vs, rereduce) {\n"
                    "  v0 = vs[0];\n"
                    "  if (!rereduce) {\n"
                    "    k0 = ks[0];\n"
                    "    if (k0 == 'y') {\n"
                    "      k0.search(/(y+)/);\n"
                    "      return RegExp.$1;\n"
                    "    };\n"
                    "    return v0;\n"
                    " } else {\n"
                    "    if (v0 == 'u') {\n"
                    "      v0.search(/(u+)/);\n"
                    "      return RegExp.$1;\n"
                    "    };\n"
                    "    return v0;\n"
                    " }\n"
                    "}"
                >>
            }
        },
        filters => #{
            f => <<
                "function(doc, req) {\n"
                " if(doc.a == 'z') {\n"
                "   doc.a.search(/(z+)/);\n"
                "   if(RegExp.$1 == 'z') {return true} else {return false};\n"
                " } else {\n"
                "   return true;\n"
                " }\n"
                "}"
            >>
        },
        validate_doc_update => <<
            "function(newdoc, olddoc, userctx, sec){\n"
            " if(newdoc.a == 'w') {\n"
            "    newdoc.a.search(/(w+)/);\n"
            "    if(RegExp.$1 == 'w') {return true} else {throw('forbidden')}\n"
            " } else {\n"
            "    return true\n"
            " }\n"
            "}"
        >>
    }),
    couch_scanner:reset_checkpoints(),
    config:set(atom_to_list(?PLUGIN), "max_batch_items", "1", false),
    {Ctx, DbName}.

teardown({Ctx, DbName}) ->
    config_delete_section("couch_scanner"),
    config_delete_section("couch_scanner_plugins"),
    config_delete_section(atom_to_list(?PLUGIN)),
    couch_scanner:reset_checkpoints(),
    couch_scanner:resume(),
    fabric:delete_db(DbName),
    test_util:stop_couch(Ctx),
    meck:unload().

t_basic({_, DbName}) ->
    meck:reset(couch_scanner_server),
    meck:reset(?PLUGIN),
    config:set("couch_scanner_plugins", atom_to_list(?PLUGIN), "true", false),
    wait_exit(10000),
    ?assertEqual(1, num_calls(start, 2)),
    case couch_server:with_spidermonkey() of
        true ->
            ?assertEqual(1, num_calls(complete, 1)),
            ?assertEqual(2, num_calls(checkpoint, 1)),
            ?assertEqual(1, num_calls(db, ['_', DbName])),
            ?assertEqual(1, num_calls(ddoc, ['_', DbName, '_'])),
            ?assert(num_calls(shards, 2) >= 1),
            DbOpenedCount = num_calls(db_opened, 2),
            ?assert(DbOpenedCount >= 2),
            ?assertEqual(1, num_calls(doc_id, ['_', ?DOC1, '_'])),
            ?assertEqual(1, num_calls(doc_id, ['_', ?DOC2, '_'])),
            ?assertEqual(1, num_calls(doc_id, ['_', ?DOC3, '_'])),
            ?assertEqual(1, num_calls(doc_id, ['_', ?DOC4, '_'])),
            ?assertEqual(1, num_calls(doc_id, ['_', ?DOC5, '_'])),
            ?assert(num_calls(doc, 3) >= 5),
            DbClosingCount = num_calls(db_closing, 2),
            ?assertEqual(DbOpenedCount, DbClosingCount),
            % start, complete and each of the 5 docs should fail = 7 total
            ?assertEqual(7, log_calls(warning));
        false ->
            ok
    end.

config_delete_section(Section) ->
    [config:delete(K, V, false) || {K, V} <- config:get(Section)].

add_doc(DbName, DocId, Body) ->
    {ok, _} = fabric:update_doc(DbName, mkdoc(DocId, Body), [?ADMIN_CTX]),
    ok.

mkdoc(Id, #{} = Body) ->
    Body1 = Body#{<<"_id">> => Id},
    jiffy:decode(jiffy:encode(Body1)).

num_calls(Fun, Args) ->
    meck:num_calls(?PLUGIN, Fun, Args).

log_calls(Level) ->
    meck:num_calls(couch_scanner_util, log, [Level, ?PLUGIN, '_', '_', '_']).

wait_exit(MSec) ->
    meck:wait(couch_scanner_server, handle_info, [{'EXIT', '_', '_'}, '_'], MSec).
