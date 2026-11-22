# What DelphiLSP answers

`ask.py` starts a private `DelphiLSP.exe` (Delphi 13's language server, not the IDE's running
copy), gives it a project the way Embarcadero's VS Code extension does (`initialize`, then
`workspace/didChangeConfiguration` with a `.delphilsp.json`), opens a file and asks for
definition, implementation and references at the places given.

```
python ask.py <project>.delphilsp.json Probe.dpr 56:13:"call through interface" 58:5:"virtual call"
```

Lines and columns are 1-based. A `.delphilsp.json` is what the IDE writes beside a project when its
Code Insight option to generate one is on (registry `Code Insight\...LSP.Pascal`, `CodeInsightLSPGenerate`); for `Probe.dpr`, copy one and set
`settings.project` to `Probe.dpr`'s `file:///` URI. Results, 22 Nov 2026: see
[`../../examples/go-to-implementation/README.md`](../../examples/go-to-implementation/README.md),
"Beside DelphiLSP".
