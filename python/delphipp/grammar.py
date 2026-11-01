"""The Delphi grammar: tree-sitter-delphi13, from a TreeSitter4D release's
DLL (tools/get-grammar.py puts it in build/), loaded by py-tree-sitter.
No C compiler needed. DELPHIPP_GRAMMAR names another DLL to use."""
from __future__ import annotations

import ctypes
import os
import pathlib
import struct
import warnings

import tree_sitter

ROOT = pathlib.Path(__file__).resolve().parents[2]
_PARSER = None


def grammar_path() -> pathlib.Path:
    env = os.environ.get('DELPHIPP_GRAMMAR')
    if env:
        return pathlib.Path(env)
    bits = 'win64' if struct.calcsize('P') == 8 else 'win32'
    return ROOT / 'build' / bits / 'tree-sitter-delphi13.dll'


def parser() -> tree_sitter.Parser:
    global _PARSER
    if _PARSER is None:
        path = grammar_path()
        if not path.exists():
            raise SystemExit(f"no grammar at {path}: run `python tools/get-grammar.py` first")
        lib = ctypes.CDLL(str(path))
        fn = lib.tree_sitter_delphi13
        fn.restype = ctypes.c_void_p
        with warnings.catch_warnings():
            warnings.simplefilter('ignore', DeprecationWarning)
            language = tree_sitter.Language(fn())
        _PARSER = (lib, tree_sitter.Parser(language))
    return _PARSER[1]
