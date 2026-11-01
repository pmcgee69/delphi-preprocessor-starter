unit AssertBasic;

interface

type
  TChecker = class
    procedure Assert(Ok: Boolean);
  end;

procedure Check(Count: Integer; X: TObject; Ok: Boolean; C: TChecker);

implementation

procedure TChecker.Assert(Ok: Boolean);
begin
end;

procedure Check(Count: Integer; X: TObject; Ok: Boolean; C: TChecker);
begin
  Assert(Count > 0);
  Assert(X <> nil, 'X is set');
  System.Assert(Ok);
  Assert(
    Count < 100);
  Assert(X.ClassName <> 'it''s');
  C.Assert(Ok);
end;

end.
