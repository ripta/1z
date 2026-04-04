ONEZ := ../../zig-out/bin/1z

.PHONY: run build build-static clean

run:
	$(ONEZ) ffi-math.1z

build:
	$(ONEZ) build ffi-math.1z -o ffi-math

build-static:
	$(ONEZ) build ffi-math.1z -o ffi-math-static --link-static=m

clean:
	rm -f ffi-math ffi-math-static
