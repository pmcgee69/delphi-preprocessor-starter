unit Errors;

interface

procedure Hidden;
procedure Twice(A: Integer); overload;
procedure Twice(A, B: Integer); overload;
/// <summary>Documented already.</summary>
procedure Done;
procedure Fine(A: Integer);

implementation

procedure Hidden;
begin
end;

procedure Twice(A: Integer);
begin
end;

procedure Twice(A, B: Integer);
begin
end;

procedure Done;
begin
end;

procedure Fine(A: Integer);
begin
end;

end.

[Missing] Declared nowhere.

[Twice] Which one?

[Done] Twice documented.

[Hidden] A procedure.
  Result: nothing.

[Fine] Fine, but for its parameters.
  A: the one it has.
  B: one it hasn't.

[Fine] A second footnote.
