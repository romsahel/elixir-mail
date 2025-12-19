# Makefile for GMime NIF

# Detect platform
UNAME_S := $(shell uname -s)

# Erlang/Elixir paths
ERL_INCLUDE := $(shell erl -noshell -eval 'io:format("~s", [lists:concat([code:root_dir(), "/erts-", erlang:system_info(version), "/include"])])' -s init stop)
ERL_INTERFACE_INCLUDE := $(shell erl -noshell -eval 'io:format("~s", [code:lib_dir(erl_interface, include)])' -s init stop)
ERL_INTERFACE_LIB := $(shell erl -noshell -eval 'io:format("~s", [code:lib_dir(erl_interface, lib)])' -s init stop)

# Compiler flags
CFLAGS = -O3 -std=gnu99 -fPIC -Wall -Wextra
CFLAGS += -I$(ERL_INCLUDE)
CFLAGS += -I$(ERL_INTERFACE_INCLUDE)

# GMime detection via pkg-config
GMIME_CFLAGS := $(shell pkg-config --cflags gmime-3.0 2>/dev/null)
GMIME_LIBS := $(shell pkg-config --libs gmime-3.0 2>/dev/null)

# Check if GMime was found
ifeq ($(GMIME_CFLAGS),)
    $(error GMime 3.0 not found. Please install GMime development package: \
        Ubuntu/Debian: sudo apt-get install libgmime-3.0-dev \
        macOS: brew install gmime)
endif

CFLAGS += $(GMIME_CFLAGS)

# Platform-specific settings
ifeq ($(UNAME_S),Darwin)
    LDFLAGS = -dynamiclib -undefined dynamic_lookup
    SO_EXT = .so
else ifeq ($(UNAME_S),Linux)
    LDFLAGS = -shared -fPIC
    SO_EXT = .so
else
    $(error Unsupported platform: $(UNAME_S))
endif

LDFLAGS += $(GMIME_LIBS)

# Source and output
SRC = gmime_nif.c gmime_parser.c
TARGET = ../priv/gmime_nif$(SO_EXT)

# Build rules
all: $(TARGET)

$(TARGET): $(SRC)
	@mkdir -p ../priv
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^
	@echo "Built $(TARGET) successfully"

clean:
	rm -f $(TARGET)
	rm -f *.o

.PHONY: all clean
