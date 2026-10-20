# Builds the spike binary.  Inside the image everything is rebuilt from
# scratch (the COPY gives every file the same mtime), which is what makes it a
# useful expensive step.
CC ?= cc
CFLAGS ?= -O2 -g
SRCS := $(wildcard src/*.c)
OBJS := $(SRCS:src/%.c=%.o)

ddcheck: $(OBJS)
	$(CC) $(CFLAGS) -o $@ $^ -lm

%.o: src/%.c src/ddcheck.h
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f *.o ddcheck

.PHONY: clean
