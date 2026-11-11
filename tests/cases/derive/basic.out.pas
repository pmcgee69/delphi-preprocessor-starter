unit Basic;

interface

type
  TSize = (Small, Medium, Large);
  TSizeHelper = record helper for TSize
    function ToString: string;
  end;

  TPlain = (One, Two);

  TSuit = (Hearts = 1, Spades = 4);
  TSuitHelper = record helper for TSuit
    function ToString: string;
  end;

function Describe(S: TSize): string;

implementation

uses
  System.SysUtils;

function TSizeHelper.ToString: string;
begin
  case Self of
    TSize.Small:  Result := 'Small';
    TSize.Medium: Result := 'Medium';
    TSize.Large:  Result := 'Large';
  else
    Result := '';
  end;
end;

function TSuitHelper.ToString: string;
begin
  case Self of
    TSuit.Hearts: Result := 'Hearts';
    TSuit.Spades: Result := 'Spades';
  else
    Result := '';
  end;
end;

type
  TLocal = (Near, Far);
  TLocalHelper = record helper for TLocal
    function ToString: string;
  end;

function TLocalHelper.ToString: string;
begin
  case Self of
    TLocal.Near: Result := 'Near';
    TLocal.Far:  Result := 'Far';
  else
    Result := '';
  end;
end;

function Describe(S: TSize): string;
begin
  Result := S.ToString + ' ' + TSuit.Spades.ToString + ' ' + TLocal.Far.ToString;
end;

end.
