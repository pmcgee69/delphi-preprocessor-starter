program Derived;

{$APPTYPE CONSOLE}
{$SCOPEDENUMS ON}

type
  TLight = (Red, Amber, Green);
  TLightHelper = record helper for TLight
    function ToString: string;
  end;

function TLightHelper.ToString: string;
begin
  case Self of
    TLight.Red:   Result := 'Red';
    TLight.Amber: Result := 'Amber';
    TLight.Green: Result := 'Green';
  else
    Result := '';
  end;
end;

begin
  for var L := Low(TLight) to High(TLight) do
    Writeln(L.ToString);
end.
