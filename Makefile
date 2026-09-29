# Thin wrapper around build.sh. Override the compiler with: make SPCOMP=/path/to/spcomp
.PHONY: all clean

all:
	SPCOMP="$(SPCOMP)" ./build.sh

clean:
	rm -f plugins/l4d2_invasion.smx
