# TODO

## Guit show

- Fix `Guit show` window opening so commit views create their own windows instead of reusing existing ones in a way that breaks the surrounding layout and navigation behavior.

## Guit blame

- Investigate blame cursor alignment when the focused target is a Fugitive diff window with collapsed regions. In some cases the blame cursor can drift slightly past the lower visible boundary. This is not critical, but should be smoothed without regressing diff/fold synchronization.
