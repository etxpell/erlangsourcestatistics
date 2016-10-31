-module(ess_engine).
-include("ess.hrl").

-export([dir/1,
         dir/2,
         quality/2]).

quality(T = #tree{type=function}, Opts) ->
    RV = T#tree.raw_values,
    QP = calculate_quality_penalty(RV, Opts),

    io:format("  RV-function:~p~n",[RV]),
    io:format("QP-function:~p~n",[QP]),

    T#tree{quality_penalty = QP,
           quality = 100 - lists:sum([V||{_,V}<-QP])
          };
quality(T = #tree{type=file}, Opts) ->
    CS = T#tree.children,
    CS2 = [ quality(C, Opts) || C <- CS],
    CQP = lists:flatten([ C#tree.quality_penalty || C <- CS2 ]),
    RV = T#tree.raw_values,
    QP = calculate_quality_penalty(RV, Opts),
    QP2 = key_sum(QP ++ CQP),

    io:format("  RV-file:~p~n",[RV]),
    io:format("QP-file:~p~n",[QP2]),

    T#tree{children = CS2,
           quality_penalty = QP2,
           quality = 100 - lists:sum([V||{_,V}<-QP2])
          };
quality(T = #tree{type=dir}, Opts) ->
    CS = T#tree.children,
    CS2 = [ quality(C, Opts) || C <- CS],
    CQP = lists:flatten([ C#tree.quality_penalty || C <- CS2 ]),

%%    io:format("QP-dir:~p~n",[CQP]),

    T#tree{children = CS2,
           quality_penalty = key_sum(CQP),
           quality = 100 - lists:sum([V||{_,V}<-CQP])
          }.

key_sum(Proplist) ->
    Keys = lists:usort([K||{K,_}<-Proplist]),
    [ {K, lists:sum(get_all_values(K,Proplist))} || K <- Keys ].

calculate_quality_penalty(RawValues, Opts) ->
    Metrics = gv(metrics, Opts),
    [ penalty_for(M, RawValues) || M <- Metrics ].


-define(MAX_PENALTY, 10).

penalty_for({Key, {Min, Max}}, Values) ->
    Penalty = lists:sum([ penalty(V, Min, Max) ||  {K,V} <- Values, K == Key ]),
    {Key, Penalty}.

penalty(undefined, _, _) -> 0;
penalty(#val{avg=Avg}, Min, Max) ->
    penalty(Avg, Min, Max);

penalty(Val, Min, _) when Val < Min -> 0;
penalty(Val, _, Max) when Val > Max -> ?MAX_PENALTY;
penalty(Val, Min, Max)  ->
    Penalty = ((Val - Min) / (Max - Min)) * ?MAX_PENALTY,
    round(Penalty).

dir(Dir) ->
    dir(Dir, []).
dir(Dir, Opts) ->
    IncDirs = find_hrl_dirs(Dir, Opts),
    add_parse_transform_dir(Opts),
    IncDirOpt = make_inc_compiler_opt(IncDirs),

    reset_log(),
    log("options:~p~n"
        "incdirs:~p~n",[Opts, IncDirOpt]),

    ForEachFileFun = fun(File) -> file(File, Opts, IncDirOpt) end,
    find_files(Dir, ForEachFileFun, Opts).

make_inc_compiler_opt(L) ->
    [{i,IC} || IC <- L ].

add_parse_transform_dir(Opts) ->
    case gv(parse_transform_beam_dirs, Opts) of
        Dirs = [[_|_]|_] ->
            [ add_path(D) || D <- Dirs ];
        Dir = [_|_] ->
            add_path(Dir);
        _ ->
            ok
    end.

add_path(Path) ->
    code:add_patha(Path).

find_hrl_dirs(Dir, Opts) ->
    BlackList = gv(exclude_dir_patterns, Opts, []) ++
                gv(exclude_dir_patterns_during_hrl_search, Opts, []),
    case gv(include_paths, Opts, []) of
        [] ->
            find_dirs(".hrl", Dir, BlackList);
        Paths ->
            find_in_subdirs(".hrl", Paths, BlackList)
    end.

find_dirs(Ext, Dir, BlackList) ->
    Fs = list_dir_full_names(Dir),
    HasFiles = any_file_has_extension(Ext, Fs),
    WhiteDirs = remove_blacklisted(BlackList, Fs),
    SubDirs = find_in_subdirs(Ext, WhiteDirs, BlackList),
    if HasFiles -> [Dir | SubDirs];
       true -> SubDirs
    end.

find_in_subdirs(Ext, Dirs, BlackList) ->
    lists:concat([ find_dirs(Ext, D, BlackList) || D <- Dirs ]).

any_file_has_extension(Ext, Fs) ->
    lists:any(fun(F) -> filename:extension(F) == Ext end, Fs).

remove_blacklisted(BlackList, Fs) ->
    lists:filter(fun(F) -> not is_blacklisted(BlackList, F) end, Fs).

is_blacklisted(BlackList, F) ->
    lists:any(fun(B) -> is_string_in_name(F, B) end, BlackList).

is_erlang_source_file(F) ->
    filename:extension(F) == ".erl".

files_ending_in_erl(Fs) ->
    lists:filter(fun is_erlang_source_file/1, Fs).

list_dir_full_names(Dir) ->
    case file:list_dir(Dir) of
        {ok, Fs} -> mk_fullnames(Dir, Fs);
        _ -> []
    end.

mk_fullnames(Dir, Fs) ->
    [ filename:join(Dir, F) || F <- Fs ].

is_string_in_name(Name, String) ->
    string:str(Name, String) /= 0.


find_files(Dir, ForEachFileFun, Opts) ->
    BlackList = gv(exclude_dir_patterns_during_analysis, Opts, []) ++
                gv(exclude_dir_patterns, Opts, []),
    find_files2(Dir, BlackList, ForEachFileFun).

find_files2(Dir, BlackList, ForEachFileFun) ->
    Fs = list_dir_full_names(Dir),
    WhiteFs = remove_blacklisted(BlackList, Fs),
    SrcFiles = files_ending_in_erl(WhiteFs),
    SubDirs = find_in_subdirs_par(WhiteFs, BlackList, ForEachFileFun),
    if (SrcFiles/=[]) andalso (SubDirs/=[]) ->
            io:format("Warning, dir contains both source files and dirs: ~p~n",
                      [Dir]);
       true -> ok
    end,
    Stats = for_each_file_par(SrcFiles, ForEachFileFun) ++ SubDirs,
    #tree{type = dir,
          name = Dir,
          children = Stats}.

find_in_subdirs_par(Dirs, BlackList, ForEachFileFun) ->
    Fun = fun(D) -> find_files2(D, BlackList, ForEachFileFun) end,
    RecData = run_fun_async(Dirs, Fun),
    prune_empties(receive_answers(RecData)).

prune_empties(L) ->
    lists:filter(fun is_not_empty/1, L).

is_not_empty({_, [], []}) -> false;
is_not_empty(_) -> true.

for_each_file_par(Files, Fun) ->
    RecData = run_fun_async(Files, Fun),
    receive_answers(RecData).

run_fun_async(Fs, Fun) ->
    [run_one_async(F, Fun) || F <- Fs].

run_one_async(F, Fun) ->
    Me = self(),
    {spawn(fun() ->
                   Res = (catch Fun(F)),
                   Me ! {self(), Res}
           end), F}.

receive_answers(L) ->
    [receive {Pid, Res} -> Res after 150000 -> {timeout, F} end
     || {Pid, F} <- L].


file(F, Opts, IncPaths) ->
    try
        CompileOpts = get_compile_options(),
        {ok,Mod,Bin,Warnings} = compile:file(F,CompileOpts ++ IncPaths),
        {ok,{Mod,[{abstract_code,{raw_abstract_v1,AST}}]}} =
            beam_lib:chunks(Bin,[abstract_code]),
        RawValues = file_raw_values(AST, Warnings, F, Opts),        
        RawChildren = analyse_functions(AST, Opts),
        io:format("  f: ~s: ok~n", [F]),
        #tree{type = file,
              name = F,
              raw_values = RawValues,
              children = RawChildren
             }
    catch
        _:Err ->
            io:format("  f: ~s: error: ~p~n", [F, error_digest(Err)]),
            log("f: ~p ~p ~p~n",[F, Err, erlang:get_stacktrace()]),
            undefined
    end.

error_digest({badmatch, {error, [{_, [{_,epp, {include, file, IncFile}}|_]}|_],_}
             }) ->
    "missing_include: "++IncFile;
error_digest(_) ->
    "error".

reset_log() ->
    file:delete("/tmp/ess_errors.log").

log(Fmt, Args) ->
    Message = io_lib:format(Fmt, Args),
    file:write_file("/tmp/ess_errors.log", Message, [append]).

get_all_values(K, Proplist) ->
    [ V || {Key,V} <- Proplist, Key == K ].

get_compile_options() ->
    [binary,verbose, debug_info, return].

lexical_analyse(F, _Opts) ->
    {ok, Bin} = file:read_file(F),
    lexical_analyse_string(binary_to_list(Bin)).

lexical_analyse_string(Str) ->
    Lines = strip_lines(divide_into_lines(Str)),
    seq_accum([], Lines,
              [fun count_comment_and_code_lines/1,
               fun analyse_space_after_comma/1]).

count_comment_and_code_lines(L) ->
    Tot = length(L),
    LineLengths = line_lengths(L),
    {Code, Comment, Blank} = count_comment_and_code_lines2(L, 0, 0, 0),
    Values = [{total_lines, Tot},
              {lines_of_code, Code},
              {lines_of_comments, Comment},
              {line_lengths, LineLengths},
              {blank_lines, Blank}],
    handle_comment_percent(Values).

count_comment_and_code_lines2([], Code, Comment, Blank) ->
    {Code, Comment, Blank};
count_comment_and_code_lines2([[] | Ls], Code, Comment, Blank) ->
    count_comment_and_code_lines2(Ls, Code, Comment, Blank+1);
count_comment_and_code_lines2([L | Ls], Code, Comment, Blank) ->
    case is_comment_line(L) of
        true ->
            count_comment_and_code_lines2(Ls, Code, Comment+1, Blank);
        _ ->
            count_comment_and_code_lines2(Ls, Code+1, Comment, Blank)
    end.

is_comment_line("%"++_) -> true;
is_comment_line(_) -> false.

line_lengths(Ls) ->
    N = length(Ls),
    Lengths =[ length(L) || L <- Ls ],
    Max = lists:max(Lengths),
    Min = lists:min(Lengths),
    Sum = lists:sum(Lengths),
    Mean = round(Sum / N),
    #val{max=Max, min=Min, avg=Mean, sum=Sum, n=N}.

analyse_space_after_comma(Ls) ->
    Faults = sum([ sac(L) || L <- Ls, not is_comment_line(L) ]),
    [{space_after_comma, Faults}].

sac([$,,$ | L]) ->
    sac(L);
sac([$,]) ->
    0;
sac([$,| L]) ->
    1+sac(L);
sac([_| L]) ->
    sac(L);
sac([]) ->
    0.

divide_into_lines(Str) ->
    dil(Str,[],[]).

dil([],[],Res) ->
    rev(Res);
dil([],Current,Res) ->
    rev([rev(Current)|Res]);
dil([$\n|R],Current,Acc) ->
    dil(R,[],[rev(Current)|Acc]);
dil([C|R],Current,Acc) ->
    dil(R,[C|Current],Acc).

strip_lines(Ls) ->
    [string:strip(L) || L <- Ls ].

file_raw_values(AST, Warnings, F, Opts) ->
    EA = export_all_metric(AST),
    WM = warning_metric(Warnings),
    LA = lexical_analyse(F, Opts),
    [ EA, WM | LA ].

export_all_metric([]) ->
    {export_all, 0};
export_all_metric([{attribute, _, compile, export_all}|_]) ->
    {export_all, 1};
export_all_metric([_|T]) ->
    export_all_metric(T).

analyse_functions(AST, _Opts) ->
    [ analyze_function(F) || F <- AST, is_ast_function(F) ].

handle_comment_percent(L) ->
    Percent = calculate_comment_to_line_percent(L),
    replace_tag(comment_to_line_percent, Percent, L).

calculate_comment_to_line_percent(L) ->
    Lines = value_sum(gv(total_lines,L)),
    Comments = value_sum(gv(lines_of_comments,L)),
    round(100*(Comments/Lines)).

value_sum(#val{sum=Sum}) -> Sum;
value_sum(X) when is_integer(X) -> X.

analyze_function(AST={function, _, _Name, _, _}) ->
    #tree{type = function,
          name = make_name(AST),
          raw_values = [{function_naming, function_naming(AST, false)},
                        {variable_naming, variable_naming(AST)},
                        {nested_clauses, nested_clauses(AST)},
                        {complexity, complexity(AST)},
                        {expressions_per_function, lines_per_function(AST)},
                        {clauses, clauses_per_function(AST)},
                        {arity, function_arity(AST)},
                        {expressions_per_line, expressions_per_function_line(AST)},
                        {variable_steppings, variable_steppings_per_function(AST)}
                       ]}.


%% --------------------------------------------------
function_naming({function, _, Name, _, _Clauses}, _FromMatch) ->
    snake_case(Name).

%% --------------------------------------------------
variable_naming(AST) ->
    NodeF = fun variable_naming_node/2,
    Gen  = fun variable_naming_gen/2,
    History = #hist{},
    ess_ast:traverse(AST, NodeF, Gen, History).

variable_naming_node(Value, Chs) ->
    Value + sum(Chs).

variable_naming_gen({var, _, V}, H) ->
    case H#hist.match > 0 of
        true ->
            camel_case(V);
        false ->
            0
    end;
variable_naming_gen({atom, _, A}, _) ->
    snake_case(A);
variable_naming_gen(_, _) ->
    0.

%% --------------------------------------------------
warning_metric(Warnings) ->
    {warnings, length(Warnings)}.

%% --------------------------------------------------
expressions_per_function_line({function, _, _, _, Clauses}) ->
    LNs = [ get_toplevel_linenumbers(C) || C <- Clauses],
    ROSL = repeats_on_same_line(lists:flatten(LNs)),
    calc_avg(#val{max=lists:max(ROSL),
                  min=lists:min(ROSL),
                  sum=sum(ROSL),
                  n=length(ROSL)}).

calc_avg(V=#val{n=0}) ->
    V#val{avg = 0};
calc_avg(V=#val{n=N, sum=Sum}) ->
    V#val{avg = round(Sum / N)}.

%% --------------------------------------------------
lines_per_function(AST) ->
    LNs = get_linenumbers(AST),
    length(lists:usort(lists:flatten(LNs))).

is_ast_function(X) when element(1,X) == function -> true;
is_ast_function(_) -> false.

function_clauses(F) ->
    element(5, F).

function_arity(AST) ->
    element(4, AST).

clauses_per_function(AST) ->
    length(function_clauses(AST)).

%% --------------------------------------------------
variable_steppings_per_function({function,_,_,_,Clauses}) ->
    sum([ variable_steppings_in_body(Clause) || Clause <- Clauses ]).

variable_steppings_in_body({clause,_,Arguments,_,Body}) ->
    Arg_Variables = extract_variables(Arguments),
    Body_Variables = extract_variables(Body),
    Variables = usort(Arg_Variables++Body_Variables),
    stepping(Variables).

extract_variables([{var,_,V}|R]) ->
    [atom_to_list(V) | extract_variables(R)];
extract_variables([E|R]) when is_tuple(E) ->
    extract_variables(tuple_to_list(E))++
        extract_variables(R);
extract_variables([E|R]) when is_list(E) ->
    extract_variables(E)++
        extract_variables(R);
extract_variables([_|R]) ->
    extract_variables(R);
extract_variables(_) ->
    [].

stepping(Vars) ->
    trailing_int(Vars) + leading_new(Vars) + leading_old(Vars).

trailing_int([]) ->
    0;
trailing_int([_]) ->
    0;
trailing_int([V1, V2 | R]) ->
    case is_variable_stepping(V1, V2) of
        true ->
            1 + trailing_int([V2 | R]);
        _ ->
            trailing_int([V2 | R])
    end.

leading_new(Vars) ->
    leading_string("New", Vars).

leading_old(Vars) ->
    leading_string("Old", Vars).


leading_string(Str, Vars) ->
    News = [ V || V <- Vars, is_leading_str(Str, V)],
    Others = Vars -- News,
    Found = lists:filter(
        fun(Other) ->
            lists:member(Str++Other, News)
        end,
        Others),
    length(Found).

is_leading_str(Str, Name) ->
    case string:str(Name, Str) of
        1 -> true;
        _ -> false
    end.

is_variable_stepping([X|V1], [X|V2]) ->
    is_variable_stepping(V1, V2);
is_variable_stepping([], V2) ->
    is_all_integers(V2);
is_variable_stepping(V1, V2) ->
    is_all_integers(V1) andalso is_all_integers(V2).

is_all_integers(L) ->
    lists:all(fun is_ascii_integer/1, L).

is_ascii_integer(X) when (X>=$0), (X=<$9) -> true;
is_ascii_integer(_) -> false.

%% --------------------------------------------------
complexity(AST) ->
    NodeF = fun complexity_node/2,
    Gen  = fun complexity_gen/2,
    History = #hist{},
    ess_ast:traverse(AST, NodeF, Gen, History).

complexity_node(Val, Chs) -> 
    Val + max(Chs).

complexity_gen({record_field, _, _, _, _}, _) ->
    2;
complexity_gen({tuple, _, Elements}, H) ->
    FromMatchLHS = H#hist.lhs > 0,
    case FromMatchLHS andalso (length(Elements) > 2) of
        true ->
            length(Elements);
        false ->
            1
    end;
complexity_gen(AST, _) ->
    case is_complexity_plus_one(AST) of
        true -> 1;
        _ -> 0
    end.

-define(COMPLEXITY_PLUS_ONE_TYPE_LIST, 
        [call, bin, record, record_index, op, lc,
         'catch', 'fun', 'try', block, bc, call, bin]).

is_complexity_plus_one(AST) when is_tuple(AST) ->
    is_complexity_plus_one(element(1, AST));
is_complexity_plus_one(Type) ->
    lists:member(Type, ?COMPLEXITY_PLUS_ONE_TYPE_LIST).


%% --------------------------------------------------
nested_clauses(AST) ->
    NodeF = fun nested_clauses_node/2,
    Gen  = fun nested_clauses_gen/2,
    History = #hist{},
    ess_ast:traverse(AST, NodeF, Gen, History).

nested_clauses_node(Val, Chs) ->
    Val + max(Chs).

nested_clauses_gen(AST, Hist) ->
    case is_leaf(AST) of
        true ->
            get_clause_depth(Hist);
        false ->
            0
    end.

get_clause_depth(#hist{'case' = C,
                       'try' = T,
                       'if' = I,
                       'receive' = R,
                       'block' = B}) ->
    C + T + I + R + B.

%% ------------------------------------------------------------
repeats_on_same_line(LNs) ->
    repeats_on_same_line(LNs,hd(LNs),0).

repeats_on_same_line([N|R],N,Counted) ->
    repeats_on_same_line(R,N,Counted+1);
repeats_on_same_line([N|R],_,Counted) ->
    [ Counted | repeats_on_same_line(R,N,1) ];
repeats_on_same_line([],_,Counted) ->
    [ Counted ].


get_toplevel_linenumbers({clause,_Line,_,_,Expressions}) ->
    [element(2,L) || L <- Expressions].


get_linenumbers({function,_Line,_,_,Clauses}) ->
    [ get_linenumbers(C) || C <- Clauses ];
get_linenumbers({clause,_Line,_,_,Expressions}) ->
    get_linenumbers_body(Expressions).

get_linenumbers_body([]) ->
    [];
get_linenumbers_body([{match,L,LHS,RHS}|R]) ->
    RHSLines = get_linenumbers_body([RHS]),
    LHSLines = get_linenumbers_body([LHS]),
    [L|LHSLines]++RHSLines++get_linenumbers_body(R);
get_linenumbers_body([{'case',L,_,Clauses}|R]) ->
    CaseLines = get_linenumbers_body(Clauses),
    [L|CaseLines] ++ get_linenumbers_body(R);
get_linenumbers_body([{'receive', L, Clauses}|R]) ->
    CaseLines = get_linenumbers_body(Clauses),
    [L|CaseLines] ++ get_linenumbers_body(R);
get_linenumbers_body([{'receive', L, Clauses, _, AfterExprs}|R]) ->
    CaseLines = get_linenumbers_body(Clauses),
    AfterLines = get_linenumbers_body(AfterExprs),
    [L|CaseLines++AfterLines] ++ get_linenumbers_body(R);
get_linenumbers_body([{'call',L,_, Args}|R]) ->
    ArgsLines = get_linenumbers_body(Args),
    [L|ArgsLines] ++ get_linenumbers_body(R);
get_linenumbers_body([{'try',L,CallExprs,_,Exprs,_}|T])->
    CallLines = get_linenumbers_body(CallExprs),
    CatchLines = get_linenumbers_body(Exprs),
    [L|CallLines++CatchLines] ++ get_linenumbers_body(T);
get_linenumbers_body([{clause,L,_,_,Expressions}|R]) ->
    BodyLines = get_linenumbers_body(Expressions),
    [L|BodyLines] ++ get_linenumbers_body(R);
get_linenumbers_body([{nil,L}|R]) ->
    [L|get_linenumbers_body(R)];
get_linenumbers_body([{op,L,_,_,_}|R]) ->
    [L|get_linenumbers_body(R)];
get_linenumbers_body([{Marker,LN,_}|T]) when is_atom(Marker) ->
    [LN|get_linenumbers_body(T)];
get_linenumbers_body([{Marker,LN,_,_}|T]) when is_atom(Marker) ->
    [LN|get_linenumbers_body(T)];
get_linenumbers_body([{Marker,LN,_,_,_}|T]) when is_atom(Marker) ->
    [LN|get_linenumbers_body(T)].

snake_case(Input) ->
    case is_snake_cased(to_string(Input)) of
        true -> 0;
        _ -> 1
    end.

is_snake_cased(String) ->
    OnlyLowerCase = string:to_lower(String) == String,
    HasUnderscore = lists:member($_, String),
    IMN = is_module_name(String),
    OnlyLowerCase or HasUnderscore or IMN.

is_module_name(String) ->
    index_of_first_uppercase(String) =< 4.

index_of_first_uppercase(S) ->
    index_of_first_uppercase(1, S).

index_of_first_uppercase(_, []) ->
    0;
index_of_first_uppercase(Ix, [C|_]) when C =< $Z, C >= $A ->
    Ix;
index_of_first_uppercase(Ix, [_|Cs]) ->
    index_of_first_uppercase(Ix+1, Cs).

camel_case(Input) ->
    case is_camel_cased(to_string(Input)) of
        true -> 0;
        _ ->  1
    end.

is_camel_cased([$_|_]) ->
    true;
is_camel_cased(String) when length(String) > 3 ->
    HasUpperCase = string:to_lower(String) /= String,
    HasLowerCase = string:to_upper(String) /= String,
    HasUnderscore = lists:member($_, String),
    HasUpperCase andalso HasLowerCase andalso not HasUnderscore;
is_camel_cased(_) ->
    true.

is_leaf({function, _, _}) -> true;
is_leaf({function, _, _, _}) -> true;
is_leaf({nil, _}) -> true;
is_leaf({atom, _, _}) -> true;
is_leaf({var, _, _}) -> true;
is_leaf({string, _, _}) -> true;
is_leaf({integer, _, _}) -> true;
is_leaf({float, _, _}) -> true;
is_leaf({char, _, _}) -> true;
is_leaf(_) -> false.


%%-----------------------
%% Utilities

make_name({function, _, Name, Arity, _}) ->
    list_to_atom(lists:flatten(io_lib:format("~p|~p",[Name, Arity]))).

to_string(X) when is_atom(X) -> atom_to_list(X);
to_string(X) when is_list(X) -> X.


usort(L) -> lists:usort(L).

%%sum(A, B) -> A+B.
sum(L) -> lists:sum(L).

max([]) -> 0;
max(L) -> lists:max(L).

rev(L) -> lists:reverse(L).

replace_tag(Tag, Value, L) ->
    lists:keystore(Tag, 1, L, {Tag, Value}).

gv(Key, L) ->
    proplists:get_value(Key, L).
gv(Key, L, Def) ->
    proplists:get_value(Key, L, Def).


seq_accum(Acc, A, [F|L]) ->
    Acc2 = F(A) ++ Acc,
    seq_accum(Acc2, A, L);
seq_accum(Acc, _, []) ->
    Acc.
