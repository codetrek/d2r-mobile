"""Keep the CPU orchestration witness bound to the complete production region."""
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
start = '#if DM_NVN_SIMULATOR\nstatic id<MTLBuffer> g_sim_prepared'
end = '\n#endif\nstatic int encode_args('
if source.count(start) != 1 or source.count(end) != 1:
    raise ValueError('constant preparation region is not uniquely bounded')
begin = source.index(start) + len('#if DM_NVN_SIMULATOR\n')
finish = source.index(end, begin)
region = source[begin:finish]
if not region or len(region.encode()) > 32768:
    raise ValueError('constant preparation region exceeds its test bound')
Path(sys.argv[2]).write_text(region + '\n')
