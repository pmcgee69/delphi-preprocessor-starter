program Hello;

{$APPTYPE CONSOLE}

uses
  Greet in 'Greet.pas';    // written from Greet.dpps by the pre-build event

var
  G: TGreeting;
begin
  G.Name  := 'Delphi';
  G.Lang  := 'fr';
  G.Times := 2;
  WriteLn(Greeting(G));
  G.Lang  := 'xx';
  G.Times := 1;
  WriteLn(Greeting(G));
  Readln;
end.
