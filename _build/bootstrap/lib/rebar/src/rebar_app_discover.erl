-module(rebar_app_discover).

-export([do/2,
         format_error/1,
         find_unbuilt_apps/1,
         find_apps/1,
         find_apps/2,
         find_app/2,
         find_app/3]).

-include("rebar.hrl").
-include_lib("providers/include/providers.hrl").

do(State, LibDirs) ->
    BaseDir = rebar_state:dir(State),
    Dirs = [filename:join(BaseDir, LibDir) || LibDir <- LibDirs],
    Apps = find_apps(Dirs, all),
	%% 得到rebar.config配置文件的deps配置信息
    ProjectDeps = rebar_state:deps_names(State),
	%% 得到Deps的路径
    DepsDir = rebar_dir:deps_dir(State),
    CurrentProfiles = rebar_state:current_profiles(State),

    %% There may be a top level src which is an app and there may not
    %% Find it here if there is, otherwise define the deps parent as root
    TopLevelApp = define_root_app(Apps, State),

    %% Handle top level deps
    State1 = lists:foldl(fun(Profile, StateAcc) ->
                                 ProfileDeps = rebar_state:get(StateAcc, {deps, Profile}, []),
                                 ProfileDeps2 = rebar_utils:tup_dedup(ProfileDeps),
                                 StateAcc1 = rebar_state:set(StateAcc, {deps, Profile}, ProfileDeps2),
                                 ParsedDeps = parse_profile_deps(Profile
                                                                ,TopLevelApp
                                                                ,ProfileDeps2
                                                                ,rebar_state:opts(StateAcc1)
                                                                ,StateAcc1),
                                 rebar_state:set(StateAcc1, {parsed_deps, Profile}, ParsedDeps)
                         end, State, lists:reverse(CurrentProfiles)),

    %% Handle sub project apps deps
    %% Sort apps so we get the same merged deps config everytime
    SortedApps = rebar_utils:sort_deps(Apps),
    lists:foldl(fun(AppInfo, StateAcc) ->
                        Name = rebar_app_info:name(AppInfo),
                        case enable(State, AppInfo) of
                            true ->
                                {AppInfo1, StateAcc1} = merge_deps(AppInfo, StateAcc),
                                OutDir = filename:join(DepsDir, Name),
                                AppInfo2 = rebar_app_info:out_dir(AppInfo1, OutDir),
                                ProjectDeps1 = lists:delete(Name, ProjectDeps),
                                rebar_state:project_apps(StateAcc1
                                                        ,rebar_app_info:deps(AppInfo2, ProjectDeps1));
                            false ->
                                ?INFO("Ignoring ~s", [Name]),
                                StateAcc
                        end
                end, State1, SortedApps).

define_root_app(Apps, State) ->
    RootDir = rebar_dir:root_dir(State),
    case ec_lists:find(fun(X) ->
                               ec_file:real_dir_path(rebar_app_info:dir(X)) =:=
                                   ec_file:real_dir_path(RootDir)
                       end, Apps) of
        {ok, App} ->
            rebar_app_info:name(App);
        error ->
            root
    end.

format_error({module_list, File}) ->
    io_lib:format("Error reading module list from ~p~n", [File]);
format_error({missing_module, Module}) ->
    io_lib:format("Module defined in app file missing: ~p~n", [Module]).

merge_deps(AppInfo, State) ->
    %% These steps make sure that hooks and artifacts are run in the context of
    %% the application they are defined at. If an umbrella structure is used and
    %% they are deifned at the top level they will instead run in the context of
    %% the State and at the top level, not as part of an application.
    Default = reset_hooks(rebar_state:default(State)),
    {C, State1} = project_app_config(AppInfo, State),
    AppInfo0 = rebar_app_info:update_opts(AppInfo, Default, C),

    CurrentProfiles = rebar_state:current_profiles(State1),
    Name = rebar_app_info:name(AppInfo0),

    %% We reset the opts here to default so no profiles are applied multiple times
    AppInfo1 = rebar_app_info:apply_overrides(rebar_state:get(State1, overrides, []), AppInfo0),
    AppInfo2 = rebar_app_info:apply_profiles(AppInfo1, CurrentProfiles),

    %% Will throw an exception if checks fail
    rebar_app_info:verify_otp_vsn(AppInfo2),

    State2 = lists:foldl(fun(Profile, StateAcc) ->
                                 handle_profile(Profile, Name, AppInfo2, StateAcc)
                         end, State1, lists:reverse(CurrentProfiles)),

    {AppInfo2, State2}.

handle_profile(Profile, Name, AppInfo, State) ->
    TopParsedDeps = rebar_state:get(State, {parsed_deps, Profile}, {[], []}),
    TopLevelProfileDeps = rebar_state:get(State, {deps, Profile}, []),
    AppProfileDeps = rebar_app_info:get(AppInfo, {deps, Profile}, []),
    AppProfileDeps2 = rebar_utils:tup_dedup(AppProfileDeps),
    ProfileDeps2 = rebar_utils:tup_dedup(rebar_utils:tup_umerge(TopLevelProfileDeps
                                                               ,AppProfileDeps2)),
    State1 = rebar_state:set(State, {deps, Profile}, ProfileDeps2),

    %% Only deps not also specified in the top level config need
    %% to be included in the parsed deps
    NewDeps = ProfileDeps2 -- TopLevelProfileDeps,
    ParsedDeps = parse_profile_deps(Profile, Name, NewDeps, rebar_app_info:opts(AppInfo), State1),
    State2 = rebar_state:set(State1, {deps, Profile}, ProfileDeps2),
    rebar_state:set(State2, {parsed_deps, Profile}, TopParsedDeps++ParsedDeps).

parse_profile_deps(Profile, Name, Deps, Opts, State) ->
	%% 获得依赖应用的存储路径
    DepsDir = rebar_prv_install_deps:profile_dep_dir(State, Profile),
    Locks = rebar_state:get(State, {locks, Profile}, []),
    rebar_app_utils:parse_deps(Name
                              ,DepsDir
                              ,Deps
                              ,rebar_state:opts(State, Opts)
                              ,Locks
                              ,1).

project_app_config(AppInfo, State) ->
    C = rebar_config:consult(rebar_app_info:dir(AppInfo)),
    Dir = rebar_app_info:dir(AppInfo),
    Opts = maybe_reset_hooks(Dir, rebar_state:opts(State), State),
    {C, rebar_state:opts(State, Opts)}.

%% Here we check if the app is at the root of the project.
%% If it is, then drop the hooks from the config so they aren't run twice
maybe_reset_hooks(Dir, Opts, State) ->
    case ec_file:real_dir_path(rebar_dir:root_dir(State)) of
        Dir ->
            reset_hooks(Opts);
        _ ->
            Opts
    end.

reset_hooks(Opts) ->
    lists:foldl(fun(Key, OptsAcc) ->
                        rebar_opts:set(OptsAcc, Key, [])
                end, Opts, [post_hooks, pre_hooks, provider_hooks, artifacts]).

-spec all_app_dirs(list(file:name())) -> list(file:name()).
all_app_dirs(LibDirs) ->
    lists:flatmap(fun(LibDir) ->
                          app_dirs(LibDir)
                  end, LibDirs).

app_dirs(LibDir) ->
    Path1 = filename:join([LibDir,
                           "src",
                           "*.app.src"]),

    Path2 = filename:join([LibDir,
                           "src",
                           "*.app.src.script"]),

    Path3 = filename:join([LibDir,
                           "ebin",
                           "*.app"]),

    lists:usort(lists:foldl(fun(Path, Acc) ->
                                    Files = filelib:wildcard(ec_cnv:to_list(Path)),
                                    [app_dir(File) || File <- Files] ++ Acc
                            end, [], [Path1, Path2, Path3])).

find_unbuilt_apps(LibDirs) ->
    find_apps(LibDirs, invalid).

-spec find_apps([file:filename_all()]) -> [rebar_app_info:t()].
find_apps(LibDirs) ->
    find_apps(LibDirs, valid).

-spec find_apps([file:filename_all()], valid | invalid | all) -> [rebar_app_info:t()].
find_apps(LibDirs, Validate) ->
    rebar_utils:filtermap(fun(AppDir) ->
                                  find_app(AppDir, Validate)
                          end, all_app_dirs(LibDirs)).

-spec find_app(file:filename_all(), valid | invalid | all) -> {true, rebar_app_info:t()} | false.
find_app(AppDir, Validate) ->
    find_app(rebar_app_info:new(), AppDir, Validate).

find_app(AppInfo, AppDir, Validate) ->
    AppFile = filelib:wildcard(filename:join([AppDir, "ebin", "*.app"])),
    AppSrcFile = filelib:wildcard(filename:join([AppDir, "src", "*.app.src"])),
    AppSrcScriptFile = filelib:wildcard(filename:join([AppDir, "src", "*.app.src.script"])),
    try_handle_app_file(AppInfo, AppFile, AppDir, AppSrcFile, AppSrcScriptFile, Validate).

app_dir(AppFile) ->
    filename:join(rebar_utils:droplast(filename:split(filename:dirname(AppFile)))).

-spec create_app_info(rebar_app_info:t(), file:name(), file:name()) -> rebar_app_info:t().
create_app_info(AppInfo, AppDir, AppFile) ->
    [{application, AppName, AppDetails}] = rebar_config:consult_app_file(AppFile),
    AppVsn = proplists:get_value(vsn, AppDetails),
    Applications = proplists:get_value(applications, AppDetails, []),
    IncludedApplications = proplists:get_value(included_applications, AppDetails, []),
    AppInfo1 = rebar_app_info:name(
                 rebar_app_info:original_vsn(
                   rebar_app_info:dir(AppInfo, AppDir), AppVsn), AppName),
    AppInfo2 = rebar_app_info:applications(
                 rebar_app_info:app_details(AppInfo1, AppDetails),
                 IncludedApplications++Applications),
    Valid = case rebar_app_utils:validate_application_info(AppInfo2) =:= true
                andalso rebar_app_info:has_all_artifacts(AppInfo2) =:= true of
                true ->
                    true;
                _ ->
                    false
            end,
    rebar_app_info:dir(rebar_app_info:valid(AppInfo2, Valid), AppDir).

%% Read in and parse the .app file if it is availabe. Do the same for
%% the .app.src file if it exists.
try_handle_app_file(AppInfo, [], AppDir, [], AppSrcScriptFile, Validate) ->
    try_handle_app_src_file(AppInfo, [], AppDir, AppSrcScriptFile, Validate);
try_handle_app_file(AppInfo, [], AppDir, AppSrcFile, _, Validate) ->
    try_handle_app_src_file(AppInfo, [], AppDir, AppSrcFile, Validate);
try_handle_app_file(AppInfo0, [File], AppDir, AppSrcFile, _, Validate) ->
    try create_app_info(AppInfo0, AppDir, File) of
        AppInfo ->
            AppInfo1 = rebar_app_info:app_file(AppInfo, File),
            AppInfo2 = case AppSrcFile of
                           [F] ->
                               rebar_app_info:app_file_src(AppInfo1, F);
                           [] ->
                               %% Set to undefined in case AppInfo previous had a .app.src
                               rebar_app_info:app_file_src(AppInfo1, undefined);
                           Other when is_list(Other) ->
                               throw({error, {multiple_app_files, Other}})
                      end,
            case Validate of
                valid ->
                    case rebar_app_utils:validate_application_info(AppInfo2) of
                        true ->
                            {true, AppInfo2};
                        _ ->
                            false
                    end;
                invalid ->
                    case rebar_app_utils:validate_application_info(AppInfo2) of
                        true ->
                            false;
                        _ ->
                            {true, AppInfo2}
                    end;
                all ->
                    {true, AppInfo2}
            end
    catch
        throw:{error, {Module, Reason}} ->
            ?DEBUG("Falling back to app.src file because .app failed: ~s", [Module:format_error(Reason)]),
            try_handle_app_src_file(AppInfo0, File, AppDir, AppSrcFile, Validate)
    end;
try_handle_app_file(_AppInfo, Other, _AppDir, _AppSrcFile, _, _Validate) ->
    throw({error, {multiple_app_files, Other}}).

%% Read in the .app.src file if we aren't looking for a valid (already built) app
try_handle_app_src_file(_AppInfo, _, _AppDir, [], _Validate) ->
    false;
try_handle_app_src_file(_AppInfo, _, _AppDir, _AppSrcFile, valid) ->
    false;
try_handle_app_src_file(AppInfo, _, AppDir, [File], Validate) when Validate =:= invalid
                                                                 ; Validate =:= all ->
    AppInfo1 = create_app_info(AppInfo, AppDir, File),
    case filename:extension(File) of
        ".script" ->
            {true, rebar_app_info:app_file_src_script(AppInfo1, File)};
        _ ->
            {true, rebar_app_info:app_file_src(AppInfo1, File)}
    end;
try_handle_app_src_file(_AppInfo, _, _AppDir, Other, _Validate) ->
    throw({error, {multiple_app_files, Other}}).

enable(State, AppInfo) ->
    not lists:member(to_atom(rebar_app_info:name(AppInfo)),
             rebar_state:get(State, excluded_apps, [])).

to_atom(Bin) ->
    list_to_atom(binary_to_list(Bin)).
