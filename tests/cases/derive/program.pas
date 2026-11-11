program Derived;

{$APPTYPE CONSOLE}
{$SCOPEDENUMS ON}

type
  [Derive(ToString)]
  TLight = (Red, Amber, Green);

begin
  for var L := Low(TLight) to High(TLight) do
    Writeln(L.ToString);
end.
