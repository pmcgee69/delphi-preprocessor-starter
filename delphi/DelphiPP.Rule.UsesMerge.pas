unit DelphiPP.Rule.UsesMerge;

{ THE `uses-merge` RULE: a rewrite. It lets a file have several
  uses clauses in one section, which Delphi doesn't (dcc64: E2029 at the
  second), and merges them into the one Delphi wants:

      uses System.SysUtils, System.Classes;        uses System.SysUtils, System.Classes,
      uses System.Types;                     ->         System.Types;

  WHY: one clause per need, each with its own comment, is easier to read and to
  change than one long list; and the merged file is what dcc compiles.

  NO NEW GRAMMAR NEEDED. The standard Delphi grammar already parses several
  clauses: each is a node of its own, side by side in the section
  (bin\delphipp.exe --tree ..\tests\cases\uses-merge\basic.pas):
      interface                        line 3
        kInterface                     interface
        declUses                       line 5
          kUses                        uses
          declUsesUnit                 line 6
          ,                            ,
          declUsesUnit                 line 6
          ;                            ;
        declUses                       line 7
          kUses                        uses
          declUsesUnit                 line 7
          ;                            ;
  (each unit's own nodes left out here). So Kinds lists the sections (a program's or library's clauses sit straight
  under it), and Visit walks a section's children.

  THE EDITS: for each clause straight after another, the earlier one's `;`
  becomes `,` and the later one's `uses` goes (a space in its place when a unit
  follows on its line, for the indent). When the `uses` is alone on its line
  and no comment lies between the clauses, everything from the `;` to the
  `uses` becomes `,`, so no empty line is left between the units. Nothing else
  changes: comments, other line breaks and spacing stay where they were.

  WHAT IT LEAVES ALONE: clauses with a compiler directive between them, such as
  $IFDEF MSWINDOWS. They may be alternatives, one per platform, which Delphi
  allows and its own RTL does (System.RegularExpressionsAPI); if both can be on
  together, dcc says so. Only what the text proves is reported: a unit named
  twice in clauses being merged (dcc would say E2004), as an error. Units used
  in both interface and implementation aren't checked. }

interface

uses
  DelphiPP.Engine;

type
  TUsesMerge = class(TRule)
  public
    function Name: string; override;
    function Kinds: TArray<string>; override;
    function Description: string; override;
    procedure Visit(const Node: TNode; Ctx: TContext); override;
  end;

implementation

uses
  System.SysUtils,
  System.Generics.Collections;

// how users choose the rule (--rules uses-merge), and how its messages are signed
function TUsesMerge.Name: string;
begin
  Exit( 'uses-merge' );
end;

// the sections that can hold uses clauses, as --tree prints them
function TUsesMerge.Kinds: TArray<string>;
begin
  Result := ['program', 'library', 'interface', 'implementation'];
end;

// one line, for --list
function TUsesMerge.Description: string;
begin
  Exit( 'A rewrite: several uses clauses in a section merged into one.' );
end;

// the clause's last child, its `;`
function Semicolon(const Clause: TNode): TNode;
begin
  Exit( Clause.Child(Clause.ChildCount - 1) );
end;

type
  // a clause of a run, and whether a comment lies between it and the clause before
  TClause = record
    Node     : TNode;
    Commented: Boolean;
  end;

// one run's clauses merged: each into the one before
procedure Merge(const Run: TArray<TClause>; Ctx: TContext);
begin
  if Length(Run) < 2 then
    Exit;
  // the run's edits are one rewrite, from its first clause to its last, so an editor's hover shows
  // the clauses merged, not a `,` alone (user, 13 Nov: "the uses hover is saying almost nothing")
  const SavedStart = Ctx.VisitStart;
  const SavedEnd   = Ctx.VisitEnd;
  Ctx.VisitStart := Run[0].Node.StartByte;
  Ctx.VisitEnd   := Run[High(Run)].Node.EndByte;
  try
    for var K := 1 to High(Run) do
    begin
      const Prev = Run[K - 1].Node;
      const C = Run[K].Node;
      const SameLine = C.Child(1).Line = C.Child(0).Line;
      if SameLine or Run[K].Commented then
      begin
        Ctx.Replace(Semicolon(Prev), ',');
        // its `uses`: a space where a unit follows on the same line, so
        // `uses System.Types;` becomes `  System.Types;`
        if SameLine then
          Ctx.Replace(C.Child(0), ' ')
        else
          Ctx.Replace(C.Child(0), '');
      end
      else
        // only blanks between: the `uses` line goes with them
        Ctx.ReplaceSpan(Semicolon(Prev), C.Child(0), ',');
    end;
  finally
    Ctx.VisitStart := SavedStart;
    Ctx.VisitEnd   := SavedEnd;
  end;
end;

// called once for each section: walks its children, finding each run of clauses with nothing but
// comments between them, and merging each run
procedure TUsesMerge.Visit(const Node: TNode; Ctx: TContext);
begin
  var Run: TArray<TClause>;
  var Commented := False;   // a comment since the clause before
  // the units of the run's clauses
  var Seen := TDictionary<string, Boolean>.Create;
  try
    for var I := 0 to Node.ChildCount - 1 do
    begin
      var C := Node.Child(I);
      if C.Kind = 'declUses' then
      begin
        // each unit once in the run
        for var J := 0 to C.ChildCount - 1 do
          if C.Child(J).Kind = 'declUsesUnit' then
          begin
            const UnitName = Ctx.Text(C.Child(J).Child(0));
            if Seen.ContainsKey(UnitName.ToLower) then
              Ctx.Report(C.Child(J), UnitName + ' is used twice in this section', 'error')
            else
              Seen.Add(UnitName.ToLower, True);
          end;
        var Clause: TClause;
        Clause.Node      := C;
        Clause.Commented := Commented;
        Run := Run + [Clause];
        Commented := False;
      end
      else if C.Kind = 'comment' then
        Commented := True
      else
      begin
        // a directive (maybe alternatives follow) or a declaration: the run is over
        Merge(Run, Ctx);
        Run := nil;
        Seen.Clear;
      end;
    end;
    Merge(Run, Ctx);
  finally
    Seen.Free;
  end;
end;

end.
