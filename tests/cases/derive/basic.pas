unit Basic;

interface

type
  [Derive(ToString)]
  TSize = (Small, Medium, Large);

  TPlain = (One, Two);

  [Derive(ToString)]
  TSuit = (Hearts = 1, Spades = 4);

function Describe(S: TSize): string;

implementation

uses
  System.SysUtils;

type
  [Derive(ToString)]
  TLocal = (Near, Far);

function Describe(S: TSize): string;
begin
  Result := S.ToString + ' ' + TSuit.Spades.ToString + ' ' + TLocal.Far.ToString;
end;

end.
