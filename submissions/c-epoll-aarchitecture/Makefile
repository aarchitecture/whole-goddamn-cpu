CC      ?= gcc
# libpq headers are off the default path on Debian; fall back to pkg-config
PGINC   := $(shell pkg-config --cflags libpq 2>/dev/null || echo -I/usr/include/postgresql)
WARN    := -std=c99 -Wall -Wextra -Werror -Wstrict-prototypes \
           -Wmissing-prototypes -Wshadow -Wformat=2 -Wvla
CFLAGS  := $(WARN) -O2 -pthread -D_GNU_SOURCE -MMD -MP -Isrc $(PGINC)
LDFLAGS :=
LDLIBS  := -lpq -lssl -lcrypto -lcrypt

# not for benchmarks lol
SAN ?= 0
ifeq ($(SAN),1)
CFLAGS  := $(WARN) -O1 -g -fsanitize=address,undefined \
           -fno-omit-frame-pointer -pthread -D_GNU_SOURCE -MMD -MP -Isrc $(PGINC)
LDFLAGS := -fsanitize=address,undefined
endif

SRC  := $(shell find src -name '*.c' | sort)
OBJ  := $(SRC:.c=.o)
TEST_SRC := $(filter-out src/main.c,$(SRC))

bin/conduit: $(OBJ) | bin
	$(CC) -o $@ $(OBJ) $(LDFLAGS) $(LDLIBS)

bin:
	mkdir -p bin

-include $(OBJ:.o=.d)

src/%.o: src/%.c
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	find src -name '*.o' -o -name '*.d' | xargs -r rm
	rm -rf bin

bin/conduit-tests: tests/*.c $(TEST_SRC) | bin
	$(CC) $(CFLAGS) -o $@ tests/*.c $(TEST_SRC) $(LDFLAGS) $(LDLIBS)

# pure-module unit tests; no postgres
test: bin/conduit-tests
	./bin/conduit-tests

.PHONY: clean test
