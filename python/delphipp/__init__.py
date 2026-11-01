"""delphipp: a starting point for your own preprocessor and rules on
standard Delphi. See the repository's README."""
from .engine import run, Message, Context

__all__ = ['run', 'Message', 'Context']
