"""Print the shared library compiler source identity for owned CPU checks."""

from pathlib import Path
import sys

sys.dont_write_bytecode = True
from profile_inputs import library_contract_source

if __name__ == '__main__':
    print(library_contract_source(Path(__file__).resolve().parents[4]))
