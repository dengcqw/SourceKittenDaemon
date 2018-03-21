CC=gcc
CFLAGS=-I.
DEPS = include/fuzzyMatch.h
OBJ = fuzzyMatch.o

%.o: %.c $(DEPS)
	$(CC) -c -o $@ $< $(CFLAGS)

fuzzyMatch: $(OBJ)
	$(CC) -o $@ $^ $(CFLAGS)

.PHONY: clean

clean:
	rm -f *.o fuzzy
