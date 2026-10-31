# Get the diretory of the Julia .so Lib
JULIA_LIB := $(shell julia -e 'print(abspath(Sys.BINDIR, "../lib"))')

all:
	odin build . -out:vortice.exe -o:speed -microarch:native -no-bounds-check \
    -extra-linker-flags:"-L$(JULIA_LIB) -Wl,-rpath,$(JULIA_LIB)"

run:
	./vortice.exe

clean:
	rm -f vortice.exe
