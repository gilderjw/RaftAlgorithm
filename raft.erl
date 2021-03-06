-module(raft).
-export([start_raft_member/1,start_raft_members/1,append_log/3,make_leader/1,append_entries/4,eztest/0]).
-include_lib("eunit/include/eunit.hrl").

eztest() ->
  dbg:tracer(),
  eunit:test(raft:ld_2_test_()).

append_entries(Log,State,EntriesState,Pid) ->
	Term = maps:get(term,EntriesState),
	PrevLogIndex = maps:get(prevLogIndex,EntriesState),
	PrevLogTerm = maps:get(prevLogTerm,EntriesState),
	Entries = maps:get(entries,EntriesState),
	LeaderCommit = maps:get(leaderCommit,EntriesState),
	
	CurrentTerm = maps:get(currentTerm,State),
  CommitIndex = maps:get(commitIndex,State),
  {Success,NLog,NState} =
    % 1. Reply false if term < currentTerm (§5.1)
    if Term < CurrentTerm ->
      {false,Log,State};
    true ->
      % 2. Reply false if log doesn’t contain an entry at prevLogIndex
      % whose term matches prevLogTerm (§5.3)
      if (PrevLogIndex > length(Log)) ->
        %io:format(standard_error,"No entry at prevLogIndex",[]),
        {false,Log,maps:put(currentTerm,Term,State)};
      (PrevLogIndex == 0) ->
        %io:format(standard_error,"prevLogIndex==0",[]),
        {true,[],maps:put(commitIndex,PrevLogIndex,maps:put(currentTerm,Term,State))};
      true ->
        {MyPrevLogTerm,_} = lists:nth(PrevLogIndex,Log),
        if not (MyPrevLogTerm == PrevLogTerm) ->
          %io:format(standard_error,"MyPrevLogTerm = ~p, PrevLogTerm = ~p",[MyPrevLogTerm,PrevLogTerm]),
          % 3. If an existing entry conflicts with a new one (same index
          % but different terms), delete the existing entry and all that
          % follow it (§5.3)
          {false,lists:sublist(Log,PrevLogIndex+1),maps:put(currentTerm,Term,State)};
        true ->
          %io:format(standard_error,"No conflict, appending as usual",[]),
          {true,lists:sublist(Log,PrevLogIndex),maps:put(currentTerm,Term,State)}
        end
      end
    end,
  if not Success ->
    Pid ! {maps:get(currentTerm,NState),false,self()},
    {NLog,NState};
  true ->
    Pid ! {maps:get(currentTerm,NState),true,self()},
    % 5. If leaderCommit > commitIndex, set commitIndex =
    % min(leaderCommit, index of last new entry
    if LeaderCommit > CommitIndex ->
      NewState = maps:put(commitIndex,min(LeaderCommit,length(NLog)+length(Entries)),NState),      % 4. Append any new entries not already in the log
      {lists:append(NLog,Entries),NewState};
    true ->
      % 4. Append any new entries not already in the log
      {lists:append(NLog,Entries),NState}
    end
  end.

getNthLog(N,Log) ->
  %io:format(standard_error,"N = ~p, Log = ~p",[N,Log]),
  if (N == 0) or (length(Log) == 0) ->
    0;
  (length(Log) >= N) ->
    {A,_} = lists:nth(N,Log),
    A;
  true ->
    0
  end.

% Id,
% Term,
% PrevLogIndex,
% PrevLogTerm,
% Entries, % these will be of the form {Term,data} because you can get data from other terms
% LeaderCommit
update_member(Log,State,Pid,LastIndex) ->
  Term = maps:get(currentTerm,State),
  PrevLogTerm = getNthLog(LastIndex,Log),
  Entries = lists:nthtail(LastIndex,Log),
  LeaderCommit = length(Log),
  {_,Success} = append_entries_pid(Pid,Term,LastIndex,PrevLogTerm,Entries,LeaderCommit),
  if Success == false ->
    update_member(Log,State,Pid,LastIndex-1);
  true ->
    nothing
  end.

member(Log,State) ->
	Enabled = maps:get(enabled,State),
	if not Enabled ->
		receive
			{enable} ->
				member(Log,maps:update(enabled,true,State));
      _ ->
        member(Log,State)
		end;
	true ->
		receive
			{appendLog,Number,Value} ->			
				member(Log ++ [{Number,Value}],State);
			{getLog,Pid} ->
				Pid ! Log,
				member(Log,State);
			{getTerm,Pid} ->
				Pid ! maps:get(currentTerm,State),
				member(Log,State);
			{getCommitIndex,Pid} ->
				Pid ! maps:get(commitIndex,State),
				member(Log,State);
			{appendEntries,EntriesState,Pid} ->
        % erlang:display("appendEntries on "),
        % erlang:display(self()),
				{NewLog,NewState} = append_entries(Log,State,EntriesState,Pid),
				member(NewLog,NewState);
      {register,ListOfUniqueIds} ->
        member(Log,maps:put(peers,sets:union(maps:get(peers,State),sets:from_list(ListOfUniqueIds)),State));
      {makeLeader,Pid} ->
        NewState = maps:put(currentTerm,maps:get(currentTerm,State)+1,State),
        CommitIndex = maps:get(commitIndex,NewState),
        lists:foreach(fun(Id) ->
          append_entries(
            Id,
            maps:get(currentTerm,NewState),
            CommitIndex,
            getNthLog(CommitIndex,Log),
            [],
            CommitIndex)
        end, sets:to_list(maps:get(peers,NewState))),
        Pid ! finished,
        member(Log,NewState);
      {getPeers,Pid} ->
        Pid ! sets:to_list(maps:get(peers,State)),
        member(Log,State);
      {updateMember,Pid,LastIndex,ReturnPid} ->
        update_member(Log,State,Pid,LastIndex),
        ReturnPid ! done,
        member(Log,State);
			{disable} ->
				member(Log,maps:update(enabled,false,State))
		end
	end.

member() ->
	member([],maps:from_list([
  {peers,sets:from_list([])},
	{enabled,true},
	{currentTerm,0},
	{commitIndex,0}
	])).

start_raft_member(UniqueId) ->
  Member = spawn(fun() -> member() end),
  register(UniqueId, Member).


% THE TESTME Function sets up a test with a running raft member
% that is then killed after the test runs

setup() ->
  start_raft_member(raft1),
  start_raft_members([m1,m2,m3]),
  % Uncomment to debug sends/receives
  dbg:p(m1,[s,r]).
  % Then use dbg:tracer() to start the tracer


cleanup(_) ->
  exit(whereis(raft1),kill),
  exit(whereis(m1),kill),
  exit(whereis(m2),kill),
  exit(whereis(m3),kill),
  timer:sleep(10). % give it a little time to die

testme(Test) ->
  {setup, fun setup/0, fun cleanup/1, [ Test ] }.



% TEST 
% to run ALL tests, use raft:test()
% to run a specific test, use eunit:test(raft:ld_5_test_()).
% You can uncomment the various tests as you go.
start_raft_member_test_() ->
    testme(?_test(
              ?assert(whereis(raft1) =/= undefined)
             )).


% The first thing we will implement is simplistic storage service.
% The raft member will store a list of {num,Something} tuples.  These
% will eventually become log entries and the nums will have official
% meanings, but that's in the future.  append_log won't ever be used
% by the official raft system directly - just a test function to get
% started.  Similarly, the raft algorithm won't ever use `
% directly, but we will use it in future tests to verify the correct
% integrity of the log.

append_log(Id,Num,Something) ->
  whereis(Id) ! {appendLog,Num,Something}.

get_log(Id) ->
  whereis(Id) ! {getLog, self()},
  receive
  	Result ->
  		Result
  end.


get_log_1_test_() ->
  testme(?_test(
            ?assertEqual([],get_log(raft1))
           )).


get_log_2_test_() ->
  testme(?_test([
            ?assertEqual([],get_log(raft1)),
            append_log(raft1,1,foo),
            ?assertEqual([{1,foo}],get_log(raft1))
           ])).


% This puts the raft member in a state where it no longer responds to
% messages.  Any messages sent should be lost (i.e. not ever
% recieved), except (of course) for enable_raft_member.
disable_member(Id) ->
  whereis(Id) ! {disable}.



% This puts the raft member back in normal state
enable_member(Id) ->
    whereis(Id) ! {enable}.

get_enable_disable_test_() ->
    testme(?_test([
                   ?assertEqual([],get_log(raft1)),
                   disable_member(raft1),
                   append_log(raft1,1,foo), % should be ignored
                   enable_member(raft1),
                   ?assertEqual([],get_log(raft1))
             ])).

%%%%%%%%%%%%%%%%%%%
%% PART 2: Follower Data (30 points)
%%%%%%%%%%%%%%%%%%%

% In this section, we will implement the rules for follower log
% updating.  These can be a little complex because of the requirements
% to keeps logs consistent.  We'll handle it one step at a time.

% Firstly, your member will need to store the number of the current
% term.  This will initially be set to zero, but this number will
% increase as elections happen.

% Secondly, your member will need to store the latest index known to
% be committed.  This will initially be set to zero, but this number
% will increase data is sucessfully sent.

% About this moment, you may realize that the servers state is pretty
% complex.  You might want to research Erlang's records, dicts, and
% maps to see if you can find a good way to store key value pairs.
% You can of course store it as a touple, but updating that tuples
% representation everywhere state must be changed will make you quite
% sad..

% Write functions to get a member's current term and commit index.
% These are functions for testing -- they're not an official request
% in the Raft protocol.

get_term(Id) ->
    whereis(Id) ! {getTerm,self()},
    receive
    	Term -> Term
    end.

get_commit_index(Id) ->
    whereis(Id) ! {getCommitIndex,self()},
    receive
    	Index -> Index
    end.


get_term_and_ci_test_() ->
    testme(?_test([
                   ?assertEqual(0,get_term(raft1)),
                   ?assertEqual(0,get_commit_index(raft1))
             ])).

% Now our first real request, append entries.  This is a good one to
% start with, because it's the protocol designed to update a member
% that comes back after being crashed.

% our implementation will be as described on page 4 of the raft paper.
% This section won't think about forwarding, so you can leave the
% leaderid for a future time if you wish.

% return should be a tuple {term,success}.  BUT, this need not be the
% only thing your service actually returns - you may well find that
% you wish to add the unique id, or something about the service's
% state, or whatever.  Feel free to add data you need - now, or in
% later steps of the protocol.  Then make your append entries filter
% out everything except what my test case needs from the result

append_entries_non_blocking(Pid,
             Term,
             PrevLogIndex,
             PrevLogTerm,
             Entries, % these will be of the form {Term,data} because you can get data from other terms
             LeaderCommit) ->
  Pid ! {
    appendEntries,
    maps:from_list([
      {term,Term},
      {prevLogIndex,PrevLogIndex},
      {prevLogTerm,PrevLogTerm},
      {entries,Entries},
      {leaderCommit,LeaderCommit}
    ]),
    self()
  }.

append_entries(Id,
               Term,
               PrevLogIndex,
               PrevLogTerm,
               Entries, % these will be of the form {Term,data} because you can get data from other terms
               LeaderCommit) ->
  append_entries_non_blocking(whereis(Id),Term,PrevLogIndex,PrevLogTerm,Entries,LeaderCommit),
  receive
    {A,B,_} -> {A,B}
  after
    5 ->
      false
  end.

append_entries_pid(Pid,Term,PrevLogIndex,PrevLogTerm,Entries,LeaderCommit) ->
  Pid ! {
    appendEntries,
    maps:from_list([
      {term,Term},
      {prevLogIndex,PrevLogIndex},
      {prevLogTerm,PrevLogTerm},
      {entries,Entries},
      {leaderCommit,LeaderCommit}
    ]),
    self()
  },
  %io:format(standard_error,"Waiting~n",[]),
  receive
    {A,B,_} ->
      %io:format(standard_error,"Received~n",[]),
      {A,B}
  end.


% case 1: term is higher, prevs match, so data is added
ae1_test_() ->
    testme(?_test([
                   ?assertEqual(0,get_term(raft1)),
                   ?assertEqual(0,get_commit_index(raft1)),
                   append_entries(raft1,1,0,0,[{1,newdata}],0),
                   ?assertEqual(1,get_term(raft1)),
                   ?assertEqual(0,get_commit_index(raft1)),
                   ?assertEqual([{1,newdata}],get_log(raft1))                   
             ])).

% case 2: same as 1, plus followup with a commit
ae2_test_() ->
    testme(?_test([
                   append_entries(raft1,1,0,0,[{1,newdata}],0),
                   ?assertEqual(1,get_term(raft1)),
                   ?assertEqual(0,get_commit_index(raft1)),
                   ?assertEqual([{1,newdata}],get_log(raft1)),
                   append_entries(raft1,1,1,1,[],1),
                   ?assertEqual(1,get_term(raft1)),
                   ?assertEqual(1,get_commit_index(raft1)),
                   ?assertEqual([{1,newdata}],get_log(raft1))                   
             ])).

% case 3: 2 different data in 2 different terms
ae3_test_() ->
    testme(?_test([
                   append_entries(raft1,1,0,0,[{1,newdata}],0),
                   ?assertEqual(1,get_term(raft1)),
                   ?assertEqual(0,get_commit_index(raft1)),
                   ?assertEqual([{1,newdata}],get_log(raft1)),
                   append_entries(raft1,2,1,1,[{2,newdata2}],0),
                   ?assertEqual(2,get_term(raft1)),
                   ?assertEqual(0,get_commit_index(raft1)),
                   ?assertEqual([{1,newdata},{2,newdata2}],get_log(raft1))                   
             ])).

% case 4: 2 different data but second is ignored because it comes in an earlier term
% also in this test we check the return results of append_entries
ae4_test_() ->
    testme(?_test([
                   ?assertEqual({1,true},append_entries(raft1,1,0,0,[{1,newdata}],0)),
                   ?assertEqual({2,true},append_entries(raft1,2,1,1,[{2,newdata2}],0)),
                   ?assertEqual(2,get_term(raft1)),
                   ?assertEqual([{1,newdata},{2,newdata2}],get_log(raft1)),
                   ?assertEqual({2,false},append_entries(raft1,1,1,1,[{1,otherdata}],0)),
                   ?assertEqual(2,get_term(raft1)),
                   ?assertEqual([{1,newdata},{2,newdata2}],get_log(raft1))
             ])).

% case 5: 2 different data but second is ignored because prev stuf does not match the stored data
ae5_test_() ->
    testme(?_test([
                   ?assertEqual({1,true},append_entries(raft1,1,0,0,[{1,newdata}],0)),
                   ?assertEqual(1,get_term(raft1)),
                   ?assertEqual(0,get_commit_index(raft1)),
                   ?assertEqual([{1,newdata}],get_log(raft1)),
                   ?assertEqual({2,false},append_entries(raft1,2,5,1,[{2,newdata2}],0)), % some index in term 1 we have not seen
                   ?assertEqual({2,false},append_entries(raft1,2,1,2,[{2,newdata2}],0)), % first entry is term 2 rather than term 1
                   ?assertEqual(2,get_term(raft1)),
                   ?assertEqual(0,get_commit_index(raft1)),
                   ?assertEqual([{1,newdata}],get_log(raft1))                   
             ])).




% Now we have to think about history replacement.  What can happen is
% that a member may have some data that did not get committed, and has
% since been replaced in the consensus with some other data.  This
% busted data needs to be replaced.

% What happens initially is that the leader sends some new data, but
% that fails since the PrevLogIndex and PrevLogTerm don't match the
% leaders' view of the system.  Then the leader starts going further
% back, sending more data and moving PrevLogIndex further into it's
% history.  At some point, the leader finds the last place where their
% data matches. This is the first point where the member's element at
% that index and leader's share the same term number.  At this point,
% the member deletes all subsequent members and replaces it with the
% data the leader sends.

% case 6: we do a retry and then are about to add to history

ae_hist1_test_() ->
    testme(?_test([
                   ?assertEqual({1,true},append_entries(raft1,1,0,0,[{1,newdata}],0)),
                   ?assertEqual({1,true},append_entries(raft1,1,1,1,[{1,newdata2}],0)),
                   ?assertEqual({2,false},append_entries(raft1,2,3,1,[{2,newdata4}],0)), % some index in term 1 we have not seen
                   ?assertEqual({2,true},append_entries(raft1,2,2,1,[{1,newdata3},{2,newdata4}],0)),
                   ?assertEqual(2,get_term(raft1)),
                   ?assertEqual(0,get_commit_index(raft1)),
                   ?assertEqual([{1,newdata},{1,newdata2},{1,newdata3},{2,newdata4}],get_log(raft1))                   
             ])).
 
% case 7: we have a bogus entry that is replaced when a new leader tells us

ae_hist2_test_() ->
    testme(?_test([
                   ?assertEqual({1,true},append_entries(raft1,1,0,0,[{1,newdata}],0)),
                   ?assertEqual({1,true},append_entries(raft1,1,1,1,[{1,newdata2}],0)), %bogus
                   ?assertEqual({2,true},append_entries(raft1,2,1,1,[{2,otherdata}],0)),
                   ?assertEqual(2,get_term(raft1)),
                   ?assertEqual(0,get_commit_index(raft1)),
                   ?assertEqual([{1,newdata},{2,otherdata}],get_log(raft1))                   
             ])).

% case 8: we have both something that needs to be added and something that needs to be removed

ae_hist3_test_() ->
    testme(?_test([
                   ?assertEqual({1,true},append_entries(raft1,1,0,0,[{1,newdata}],0)),
                   ?assertEqual({1,true},append_entries(raft1,1,1,1,[{1,newdata2}],0)),
                   ?assertEqual({2,false},append_entries(raft1,2,2,2,[{2,newdata4}],0)), % a slot we know about, but not the term we expect
                   ?assertEqual({2,true},append_entries(raft1,2,1,1,[{2,newdata3},{2,newdata4}],0)),
                   ?assertEqual(2,get_term(raft1)),
                   ?assertEqual(0,get_commit_index(raft1)),
                   ?assertEqual([{1,newdata},{2,newdata3},{2,newdata4}],get_log(raft1))                   
             ])).

% case 9: same as 8, but we have to go back farther

ae_hist4_test_() ->
    testme(?_test([
                   ?assertEqual({1,true},append_entries(raft1,1,0,0,[{1,newdata}],0)),
                   ?assertEqual({1,true},append_entries(raft1,1,1,1,[{1,bad1}],0)),
                   ?assertEqual({2,true},append_entries(raft1,2,2,1,[{2,bad2}],0)),
                   ?assertEqual({3,false},append_entries(raft1,3,3,3,[{3,newdata4}],0)),
                   ?assertEqual({3,false},append_entries(raft1,3,2,3,[{3,newdata3},{3,newdata4}],0)),
                   ?assertEqual({3,true},append_entries(raft1,3,1,1,[{3,newdata2},{3,newdata3},{3,newdata4}],0)),
                   ?assertEqual(3,get_term(raft1)),
                   ?assertEqual(0,get_commit_index(raft1)),
                   ?assertEqual([{1,newdata},{3,newdata2},{3,newdata3},{3,newdata4}],get_log(raft1))                   
             ])).

% case 10: all data is destroyed by a leader

ae_hist5_test_() ->
    testme(?_test([
                   ?assertEqual({1,true},append_entries(raft1,1,0,0,[{1,newdata}],0)),
                   ?assertEqual({1,true},append_entries(raft1,1,1,1,[{1,newdata2}],0)), %bogus
                   ?assertEqual({2,true},append_entries(raft1,2,0,0,[],0)),
                   ?assertEqual(2,get_term(raft1)),
                   ?assertEqual(0,get_commit_index(raft1)),
                   ?assertEqual([],get_log(raft1))                   
             ])).

%%%%%%%%%%%%%%%%%%%
%% PART 3: Leader Basics (20 points)
%%%%%%%%%%%%%%%%%%%

% The next step will be leader behavior.  Rather than get into
% elections, let's start with dealing with entry appends.  For this we
% will need a couple of utility functions.

% Make leader will artifically cause a follower to assume the leader
% role.  The new leader should increment Term and send an empty
% append_entries to all followers so that they follow the leader.

% Note that this command violates the way the system works, so making
% some process a leader that could not normally be elected could cause
% data to be lost.
make_leader(Id) ->
  whereis(Id) ! {makeLeader,self()},
  receive
    _ -> done
  end.

% This is the equivalent of start_raft_member, except all the raft
% members should be initalized to know about each other.
start_raft_members(ListOfUniqueIds) ->
  lists:foreach(fun(Id) ->
    start_raft_member(Id),
    %NotMyId = lists:delete(Id,ListOfUniqueIds),
    whereis(Id) ! {register,ListOfUniqueIds}%NotMyId}
  end, ListOfUniqueIds).


ld_1_test_() ->
    testme(?_test([make_leader(m1), % should send message to others updating their term
                   timer:sleep(10),
                   ?assertEqual(1,get_term(m2))
             ])).

% Now write a function called new_entry.  This is the way external
% users will add an entry into the system.  This message will be sent
% to the leader, which will cause append_entries to be sent to all
% members with all the new state.  It takes only two parameters - the
% unique id of the leader and the state to add.  The leader handles
% all the details that will need to be added to make a complete
% append_entries call.
%
% Note that we do not require a particular return value for
% new_entry...practically speak you'd probably want a way to be
% notified if your entry was added, but get_log and get_commit_index
% will work fine for us in this regard.

receive_aknowledge(TotalSuccess,TotalFail,TotalResponses,Leader,CommitIndex,Data) ->
  if (TotalSuccess + TotalFail == TotalResponses) ->
    if (TotalSuccess >= (TotalResponses/2)) ->   
      true;
    true ->
      false
    end;
  true ->
    receive
      {_,true,_} ->
        receive_aknowledge(TotalSuccess+1,TotalFail,TotalResponses,Leader,CommitIndex,Data);
      {_,false,Pid} ->
        Leader ! {updateMember,Pid,CommitIndex,self()},
        receive
          done -> sendUpdate(Pid,Data)
        end,
        receive_aknowledge(TotalSuccess,TotalFail,TotalResponses,Leader,CommitIndex,Data)
    after
      5 ->
        receive_aknowledge(TotalSuccess,TotalFail+1,TotalResponses,Leader,CommitIndex,Data)
    end
  end.


sendUpdate(Pid,Data) ->
  append_entries_non_blocking(
    Pid,
    maps:get(term,Data),
    maps:get(index,Data),
    maps:get(prevTerm,Data),
    maps:get(entry,Data),
    maps:get(commitIndex,Data)).

new_entry(Id, NewEntryData) ->
  CurrentTerm = get_term(Id),
  Entry = [{CurrentTerm,NewEntryData}],
  CommitIndex = get_commit_index(Id),
  NthLog = getNthLog(CommitIndex,get_log(Id)),
  Data = #{
    term=>CurrentTerm,
    index=>CommitIndex,
    prevTerm=>NthLog,
    entry=>Entry,
    commitIndex=>CommitIndex+1
  },
  whereis(Id) ! {getPeers,self()},
  receive
    Peers ->
      PeersWithoutLeader = lists:delete(Id,Peers),
      lists:foreach(fun(NewId) -> sendUpdate(whereis(NewId),Data) end, PeersWithoutLeader),
      RA = receive_aknowledge(1,0,length(Peers),Id,CommitIndex,Data),
      if RA == true ->
        append_entries(Id,CurrentTerm,CommitIndex,NthLog,Entry,CommitIndex+1);
      true ->
        member_offline
      end
  end.

ld_2_test_() ->
    testme(?_test([make_leader(m1),
                   new_entry(m1, cool_data),
                   timer:sleep(10), % waiting, because you might not have gotten completely replicated
                   ?assertEqual([{1,cool_data}],get_log(m1)),
                   ?assertEqual([{1,cool_data}],get_log(m2)),
                   ?assertEqual([{1,cool_data}],get_log(m3)),
                   new_entry(m1, cool_data2),
                   timer:sleep(10),
                   ?assertEqual([{1,cool_data},{1,cool_data2}],get_log(m1)),
                   ?assertEqual([{1,cool_data},{1,cool_data2}],get_log(m2)),
                   ?assertEqual([{1,cool_data},{1,cool_data2}],get_log(m3))

             ])).

% On to handling the commit index.  Once greater that 50% of the
% members reply, the system should consider the new entry committed,
% update its own commit index, and send an update to all members to
% update theirs.

ld_3_test_() ->
    testme(?_test([make_leader(m1),
                   new_entry(m1, cool_data),
                   timer:sleep(10),
                   ?assertEqual(1,get_commit_index(m1)),
                   ?assertEqual(1,get_commit_index(m2)),
                   ?assertEqual(1,get_commit_index(m3)),
                   new_entry(m1, cool_data2),
                   timer:sleep(10), 
                   ?assertEqual(2,get_commit_index(m1)),
                   ?assertEqual(2,get_commit_index(m2)),
                   ?assertEqual(2,get_commit_index(m3))
             ])).

% in this case the commit index updates for 1, because 2/3 get the
% message.  But it does not update for 2, because only 1/3 get the
% message.
ld_4_test_() ->
    testme(?_test([make_leader(m1),
                   disable_member(m2),
                   new_entry(m1, cool_data),
                   timer:sleep(10),
                   ?assertEqual(1,get_commit_index(m1)),
                   ?assertEqual(1,get_commit_index(m3)),
                   disable_member(m3),
                   new_entry(m1, cool_data2),
                   timer:sleep(10),
                   ?assertEqual(1,get_commit_index(m1))
             ])).

%%%%%%%%%%%%%%%%%%%
%% PART 4: Leader Recovery (20 points)
%%%%%%%%%%%%%%%%%%%


% Now consider the case of a node that was temporarily offline.  The
% leader should remember what was acknowledged and send the data it
% thinks the service is missing until it gets acknowledged.

% HINT: when I worked on this, I discovered a bug that my leader was
% always sending the complete datastore with every append call,
% without correctly updating which services had which data.  This was
% hard to detect, because the followers would accept this (as protocol
% dictates they should).  So add some erlang:displays and make sure
% your code is working right!
ld_5_test_() ->
    testme(?_test([make_leader(m1),
                   new_entry(m1, cool_data),
                   timer:sleep(10),
                   disable_member(m3),
                   new_entry(m1, cool_data2),
                   timer:sleep(10),
                   enable_member(m3),
                   new_entry(m1, cool_data3),
                   timer:sleep(10),
                   ?assertEqual([{1,cool_data},{1,cool_data2},{1,cool_data3}],get_log(m1)),
                   ?assertEqual([{1,cool_data},{1,cool_data2},{1,cool_data3}],get_log(m2)),
                   ?assertEqual([{1,cool_data},{1,cool_data2},{1,cool_data3}],get_log(m3)),
                   ?assertEqual(3,get_commit_index(m1)),
                   ?assertEqual(3,get_commit_index(m2)),
                   ?assertEqual(3,get_commit_index(m3))
             ])).

% Now cosider the case where a follower is offline and a leader switch
% occured.  The new data will be rejected by the client until a place
% of commonality between the leader's log and the newly online members
% log, then update it to be up to speed with the leader.  Raft has a
% very specific algorithm for this - be sure to follow it and not
% develop one of your own.

ld_6_test_() ->
    testme(?_test([make_leader(m1),
                   new_entry(m1, cool_data),
                   timer:sleep(10),
                   disable_member(m3),
                   new_entry(m1, cool_data2),
                   timer:sleep(10),
                   make_leader(m2),
                   timer:sleep(10),
                   enable_member(m3),
                   new_entry(m2, cool_data3),
                   timer:sleep(10),
                   ?assertEqual([{1,cool_data},{1,cool_data2},{2,cool_data3}],get_log(m1)),
                   ?assertEqual([{1,cool_data},{1,cool_data2},{2,cool_data3}],get_log(m2)),
                   ?assertEqual([{1,cool_data},{1,cool_data2},{2,cool_data3}],get_log(m3)),
                   ?assertEqual(3,get_commit_index(m1)),
                   ?assertEqual(3,get_commit_index(m2)),
                   ?assertEqual(3,get_commit_index(m3))
             ])).

% A case where shutdown member has some bogus data

ld_7_test_() ->
    testme(?_test([make_leader(m1),
                   timer:sleep(10),
                   disable_member(m2),
                   disable_member(m3),
                   new_entry(m1, cool_data),
                   disable_member(m1),
                   enable_member(m2),
                   enable_member(m3),
                   make_leader(m2),
                   new_entry(m2, cool_data2),
                   timer:sleep(10),
                   enable_member(m1),
                   new_entry(m2, cool_data3),
                   timer:sleep(10),
                   timer:sleep(10),
                   ?assertEqual([{2,cool_data2},{2,cool_data3}],get_log(m1)),
                   ?assertEqual([{2,cool_data2},{2,cool_data3}],get_log(m2)),
                   ?assertEqual([{2,cool_data2},{2,cool_data3}],get_log(m3)),
                   ?assertEqual(2,get_commit_index(m1)),
                   ?assertEqual(2,get_commit_index(m2)),
                   ?assertEqual(2,get_commit_index(m3))
             ])).

%%%%%%%%%%%%%%%%%%%
%% PART 4: Some logistics (15 points)
%%%%%%%%%%%%%%%%%%%


% Make your leader send a "heartbeat" of empty append requests at
% regular intervals.  This serves 2 purposes - 1) prevents followers
% from deciding the leader has died and starting a new election 2)
% allows out-of-date followers who re-awaken to be brought back up to
% date.

ld_8_test_() ->
    testme(?_test([disable_member(m3),
                   make_leader(m1),
                   new_entry(m1, cool_data),
                   new_entry(m1, cool_data2),
                   timer:sleep(10),
                   enable_member(m3),
                   timer:sleep(70),
                   ?assertEqual([{1,cool_data},{1,cool_data2}],get_log(m1)),
                   ?assertEqual([{1,cool_data},{1,cool_data2}],get_log(m2)),
                   ?assertEqual([{1,cool_data},{1,cool_data2}],get_log(m3))    
             ])).

% Make followers forward new_entry requests to their current leader

forwarding_test_() ->
    testme(?_test([make_leader(m1),
                   timer:sleep(10),
                   new_entry(m2, cool_data),
                   new_entry(m3, cool_data2),
                   timer:sleep(10),
                   ?assertEqual([{1,cool_data},{1,cool_data2}],get_log(m1)),
                   ?assertEqual([{1,cool_data},{1,cool_data2}],get_log(m2)),
                   ?assertEqual([{1,cool_data},{1,cool_data2}],get_log(m3))    
             ])).


% You're done!
