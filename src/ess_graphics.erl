-module(ess_graphics).
-include("ess.hrl").
-export([generate/1]).
-compile(export_all).
-define(RESULT_DIR, "/home/etxpell/dev_patches/ESS-pages/").

-record(node,{id, name, quality, color, children_ids, collapsed=false, render=false,
              quality_penalty}).
-record(edge,{id, to}).

t() ->
    RootDir = "/local/scratch/etxpell/proj/sgc/src/",
    adjust_paths(RootDir),
    SGC = ess:dir(RootDir),
    SGC2 = ess:quality(SGC),
    Level = 100,
    SGC3 = prune_tree_on_quality(SGC2, Level),
    SGC4 = set_node_ids(SGC3),
    SGC5 = mark_collapsed_nodes(SGC4),
    SGC6 = mark_first_render(SGC5),
    RawNDS = lists:flatten(generate_node_data_set(SGC6)),
    RawEDS = lists:flatten(generate_edges_data_set(SGC6)),
    {VisibleNDS, HiddenNDS} = lists:partition(fun(N) -> N#node.render end, RawNDS),
    io:format("# nodes: ~p~n", [new_unique_id()]),
    VNDS = to_node_string(VisibleNDS),
    HNDS = to_node_string(HiddenNDS),
    VEDS = to_edge_string(RawEDS),
    generate_html_page(VNDS, VEDS, HNDS, "").

mark_collapsed_nodes(L) when is_list(L) ->
    [mark_collapsed_nodes(T) || T <- L];
mark_collapsed_nodes(T=#tree{id=Id, children=Ch}) when length(Ch) == 1 ->
    T#tree{children=mark_collapsed_nodes(Ch)};
mark_collapsed_nodes(T=#tree{id=Id, children=Ch}) ->
    T#tree{children=set_collapsed(Ch)}.

set_collapsed(L) ->
    [T#tree{collapsed=true} || T <- L].
    

mark_first_render(L) when is_list(L) ->
    [mark_first_render(T) || T <- L];
mark_first_render(T=#tree{collapsed=true}) ->
    T#tree{render=true};
mark_first_render(T=#tree{children=Ch}) ->
    T#tree{render=true, children=mark_first_render(Ch)}.

generate_html_page(NDS, EDS, HIDDEN_NDS, HIDDEN_EDS) ->
    S = "<!doctype html>
<html><head> <title>Software Quality Graph</title>
  <script type=\"text/javascript\" src=\"http://visjs.org/dist/vis.js\"></script>
  <style type=\"text/css\">
    #mynetwork {
      width: 100vw;
      height: 100vh;
      border: 1px solid lightgray;
    }

    div.vis-network-tooltip {
      position: absolute;
      visibility: hidden;
      padding: 5px;
      white-space: nowrap;

      font-family: verdana;
      font-size:14px;
      color:#000000;
      background-color: #f5f4ed;

      -moz-border-radius: 3px;
      -webkit-border-radius: 3px;
      border-radius: 3px;
      border: 1px solid #808074;

      box-shadow: 3px 3px 10px rgba(0, 0, 0, 0.2);
      pointer-events: none;
    }

  </style>
</head>
<body>
<div id=\"mynetwork\" height=100%, width=100%></div>

<script type=\"text/javascript\">
  // create an array with nodes
  var nodes = new vis.DataSet(["++NDS++"
  ]);

  // create an array with ALL nodes
  var all_nodes = new vis.DataSet(["++HIDDEN_NDS++","++NDS++"
  ]);

  // create an array with edges
  var edges = new vis.DataSet(["++EDS++"
  ]);

  // create an array with ALL edges
  var hidden_nodes = new vis.DataSet(["++HIDDEN_EDS++"
  ]);

  // create a network
  var container = document.getElementById('mynetwork');
  var data = {
    nodes: nodes,
    edges: edges
  };
  var options = {layout:{improvedLayout:true},
                 physics:{enabled:true,
                          repulsion:{nodeDistance:300}},
                 interaction:{hover:true},

                 nodes: {
                   shape: 'box',
                   font: { size: 10, color: 'black'},
                   borderWidth: 2
                 },

                 edges: {width: 1}

                 };
  var network = new vis.Network(container, data, options);

  network.on(\"doubleClick\", function (params) {
           collapse_uncollapse_node(parseInt(params.nodes));
    });

  function collapse_uncollapse_node(Id) {
       all_nodes.forEach(function(n) {
                        if(n.id == Id) {
                           if( n.collapsed ) {
                              n.children_ids.forEach(function(ChId) {
                                  add_node_with_id(ChId);
                                  add_edge_from_to(Id,ChId);
                                  n.collapsed=false;
                                  all_nodes.update(n);
                              },this);
                           }else{
                              n.children_ids.forEach(function(ChId) {
                                  remove_node_with_id(ChId);
                                  remove_edge_from(Id);
                                  n.collapsed=true;
                                  all_nodes.update(n);
                              },this);
                           }
                        }
                      },this);
    }

  function add_node_with_id(Id) {
        all_nodes.forEach(function(n) {
                        if(n.id == Id) { 
                           nodes.add(n);
                        }
                      },this);
  }

  function add_edge_from_to(Id, ChId) {
        edges.add({from: Id, to: ChId, color: 'black'});
  }

  function remove_node_with_id(Id) {
       nodes.forEach(function(n) {
                       if(n.id == Id) { 
                          nodes.remove(n);
                       }
                     },this);
  }

  function remove_edge_from(Id) {
      edges.forEach(function(e) {
                      if(e.from == Id ) {
                          edges.remove(e);
                      }
                   },this);
  }

</script>
</body>
</html>",
    file:write_file("/tmp/res.html", list_to_binary(S)).

prune_tree_on_quality(T = #tree{children = Ch}, Level) -> 
    Ch2 = [ C || C <- Ch, C#tree.quality < Level ],
    Ch3 = [ prune_tree_on_quality(C, Level) || C <- Ch2 ],
    T#tree{children = Ch3}.

set_node_ids(T = #tree{children = Ch}) ->
    Id = new_unique_id(),
    T#tree{id=Id, 
           children=set_node_ids_children(Ch)
          }.

set_node_ids_children(Ch) ->
    ChWithId = [ C#tree{id = new_unique_id()} || C <- Ch ],
    [ begin
          Id = C#tree.id,
          C#tree{children=set_node_ids_children(C#tree.children)} 
      end || C <- ChWithId ].

generate_node_data_set(T=#tree{children=Ch}) ->
    S = generate_one_node(T),
    ChDataSet = [ generate_node_data_set(C) || C <- Ch],
    [ S | ChDataSet].

generate_edges_data_set(#tree{children=[]}) ->
    [];
generate_edges_data_set(#tree{collapsed=true}) ->
    [];
generate_edges_data_set(T=#tree{id=Id, children=Ch}) ->
    ChIds = [ C#tree.id || C <- Ch, C#tree.quality < 100 ],
    Edges = [ generate_one_edge(Id, ChId) || ChId <- ChIds ],
    ChEdges = [ generate_edges_data_set(C) || C <- Ch],
    Edges ++ ChEdges.

generate_one_node(#tree{id=Id, name=Name, quality=Q, 
                        children=Ch, render=Render, collapsed=Collapsed,
                        quality_penalty=QP
                       }) ->
    Color = quality_to_color(Q),
    #node{id=Id, 
          name=filename:basename(Name), 
          quality=Q, 
          color=Color, 
          children_ids=[C#tree.id||C<-Ch],
          render=Render,
          collapsed=Collapsed,
          quality_penalty=QP
         }.

generate_one_edge(Id, ChId) ->
    #edge{id=Id, 
          to=ChId}.

quality_to_color(N) ->
    NN = max(N, 0),
    G = round(255*NN/100),
    R = 255-G,
    B = 90,
    {R, G, B}.

to_node_string(L) ->
    S = [ nice_str("{id: ~p, label: \"~s\\n~p\", color: '~s', children_ids: ~w, collapsed:~p, title:\"~s\", mass:~p, font:{size:~p, color:'black'}}", 
                  [N#node.id,
                   N#node.name,
                   round(N#node.quality),
                   rgba(N#node.color),
                   N#node.children_ids,
                   N#node.collapsed,
                   quality_penalty_to_title(N#node.quality_penalty),
                   quality_to_mass(N#node.quality),
                   quality_to_font_size(N#node.quality)
                  ])
         || N <- L],
    string:join(S, ",\n").

quality_to_mass(Q) ->
    round(10 - (10 / abs(100-Q))).

quality_to_font_size(Q) ->
    round(40 - (40 / abs(100-Q))).

quality_penalty_to_title(QP) ->
    string:join([ lists:flatten(io_lib:format("~p: ~p",[K,V])) || {K,V}<-QP],"</br> ").

to_edge_string(L) ->
    S = [nice_str("{from: ~p, to: ~p, color:'black'}", 
                  [E#edge.id, 
                   E#edge.to
                  ]) || E <- L],
    string:join(S, ",").
    
rgba({R,G,B}) ->
    "rgba("++i2l(R)++","++i2l(G)++","++i2l(B)++",1)".

nice_str(F,A) ->
    lists:flatten(io_lib:format(F, A)).

new_unique_id() ->
    Old = case get(unique_id) of
              X when is_integer(X) -> X;
              _ -> 0
          end,
    New = Old+1,
    put(unique_id, New),
    New.

%% ===================================================================================
%% ===================================================================================
%% ===================================================================================


sgc_dirs(RootDir) ->
    block_dirs(filename:join(RootDir, "src/sgc"), sgc_blocks()).

syf_dirs(RootDir) ->
    block_dirs(filename:join(RootDir, "src/syf"), syf_blocks()).

block_dirs(Dir, Blocks) ->
    [ filename:join([Dir, D, "src"]) || D <- Blocks ].

sgc_blocks() -> 
    [ b2b, cha, dia, hiw, mph, oab, reg, sgm, sgn, sni, tra, trc ].

syf_blocks() -> 
    [ blm, ccpc, comte, cpl, ecop, esc,
      gcp, generic, hcfa, om, omgen, oms, perf, plc, 
      pmf, pms, rcm, sbm, "sctp/sctp_erl", sip, smm, swm, "sys/sys_erl" ].
        
adjust_paths(Root) ->
    add_path("/local/scratch/etxpell/proj/sgc/sgc/ecop/out/").

add_path(Path) ->
    code:add_pathz(Path).


generate_all(#tree{children=[]}) ->
    [];
generate_all(Tree=#tree{children=Children}) ->
    generate(Tree),
    [ generate_all(C) || C <- Children ].

generate(Tree) ->
    {Name, Data} = tag_transpose(Tree),
    Categories = get_analyis_categories(Tree),
    DivIds = lists:seq(1,length(Categories)),
    generate_chart_page(Name, Categories, DivIds, Data).

generate_chart_page(Name, Categories, DivIds, Data) ->
    DstDir = ?RESULT_DIR,
    filelib:ensure_dir(DstDir),
    FileName = filename:join(DstDir, Name++"_analysis")++".html",
    JS = generate_js_charts(Categories, DivIds, Data),
    Divs = generate_divs(DivIds),
    Table = generate_table(Divs),
    HTML = generate_html(Table, JS),
    case file:write_file(FileName, HTML) of
        ok ->
            ok;
        Err ->
            io:format("Error writing page ~p : ~p~n",[FileName, Err])
    end.

generate_js_charts(Categories, DivIds, Data) ->
    Z = lists:zip(Categories, DivIds),
    lists:map(
      fun({Tag,DivId}) ->
              TagData = gv(Tag, Data),
              RawData = [ {get_good_name(Dir), Val} || {Dir, Val} <- TagData ],
              DataPoints = generate_datapoints(RawData),
              Header = capitalize(a2l(Tag)),
              generate_chart_js(DivId, Header, DataPoints)
      end,
     Z).

%% we need to prepare the data so that we can have generic graph generation fuanctions
%% that consume some kind of nice data format 
%% {arity, [{oab,#value{}},{reg,#value{}}...]
%% The generate_chart function should be recursive
tag_transpose(#tree{name=N, quality_penalty=Value, children=[]}) ->
    {get_good_name(N), Value};
tag_transpose(#tree{name=N, children=Children}) ->
    {get_good_name(N), tag_transpose_children(Children)}.

tag_transpose_children(Children) ->
    Tags = get_analyis_categories(Children),
    [ {Tag, tag_values(Tag, Children)}  || Tag <- Tags ].

remove_empty_trees(L) ->
    [ T || T <- L, is_record(T, tree) ].

tag_values(_, []) -> 
    [];
tag_values(Tag, [C|R]) ->
    E = {C#tree.name, gv(Tag, C#tree.quality_penalty)},
    [E|tag_values(Tag, R)].


get_analyis_categories(L) when is_list(L) ->
    get_analyis_categories(hd(L));
get_analyis_categories(#tree{quality_penalty = Values})  ->
    [ T || {T, _} <- Values ].

maximum_average(RawData) ->
    lists:max([ avg_value(Value) || {_,Value} <- RawData ]).

minimum(RawData) ->
    lists:min([ avg_value(Value) || {_,Value} <- RawData ]).

avg_value(#val{avg = Value}) ->
    Value;
avg_value(Value) when is_integer(Value) ->
    Value;
avg_value(_) ->
    0.


generate_datapoints(RawData) ->
    lists:map(fun generate_datapoint/1, RawData).

generate_datapoint({Block,#val{max=Max, avg=Avg}}) ->
    io_lib:format("{ y: ~p, z: ~p, label:\"~s\"}", [Avg, Max, Block]);
generate_datapoint({Label, Value}) ->
    io_lib:format("{ y: ~p, z: ~p, label:\"~s\"}", [Value, Value, Label]).

get_good_name(#tree{name=Dir}) ->
    get_good_name(Dir);
get_good_name(Dir) ->
    case lists:reverse(filename:split(Dir)) of
        ["src",  Block | _] -> Block;
        [FileName, "src" | _] -> filename:rootname(FileName);
        [Name |_] -> Name
    end.

gv(K,L) ->
    proplists:get_value(K,L).

a2l(X) when is_list(X) -> X;
a2l(X) when is_atom(X) -> atom_to_list(X).

i2l(X) when is_list(X) -> X;
i2l(X) when is_integer(X) -> integer_to_list(X).

capitalize([C|R]) when (C>=$a) , (C=<$z) ->
    [C-32 | R];
capitalize(L) ->
    L.

generate_divs(DivIds) ->
    [ "<div id=\"chartContainer"++i2l(Id)++"\" style=\"height: 300px; width: 100%;\"></div>"
      || Id <- DivIds].

generate_table(Divs) ->
    "<table style=\"width:100%\">"++table_with_2_elements_per_row(Divs)++
        "</table>".

table_with_2_elements_per_row([]) -> "";
table_with_2_elements_per_row([E1,E2|R]) ->
    "<tr>
      <td>"++E1++"</td>
      <td>"++E2++"</td>
    </tr>"++
    table_with_2_elements_per_row(R);
table_with_2_elements_per_row([E1]) ->
    "<tr>
      <td>"++E1++"</td>
      <td></td>
    </tr>".

generate_html(Table,JSs) ->
"<!DOCTYPE HTML>
<html>

<head>  
  <script type=\"text/javascript\">
  window.onload = function () {"
++string:join(JSs,"\n")++"
}
</script>
<script type=\"text/javascript\" src=\"http://canvasjs.com/assets/script/canvasjs.min.js\"></script>
</head>
<body>"++Table++
"</body>
</html>".

generate_chart_js(DivId, Header, DataPoints) ->
  "var chart_"++Header++" = new CanvasJS.Chart(\"chartContainer"++i2l(DivId)++"\",
    {
      zoomEnabled: true,
      animationEnabled: true,
      title:{
        text: \""++Header++"\"
      },
      axisX: {
        title:\"Block\",
        labelAngle: -30,
        interval: 1
      },
      axisY:{
        title: \""++Header++"\",
        gridThickness: 1,
        tickThickness: 1,
        gridColor: \"lightgrey\",
        tickColor: \"lightgrey\",
        lineThickness: 0,
        valueFormatString:\"#.\"
      },

      data: [
      {        
        type: \"bubble\",     
        toolTipContent: \"<span style='\\\"'color: {color};'\\\"'><strong>{label}</strong></span><br/> <strong>Max "++Header++"</strong> {z} <br/> <strong>Mean "++Header++"</strong> {y} <br/>\",

        click: function(e) { window.location.href = e.dataPoint.label+\"_analysis.html\"; },

        dataPoints: 
        ["
++string:join(DataPoints,",\n")++" 
        ]
       }
      ]
    });
   chart_"++Header++".render();
".
