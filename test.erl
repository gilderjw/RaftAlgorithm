-module(test).
-export([test/0]).
test() ->
	if
		true ->
			b;
		true ->
			c
	end.