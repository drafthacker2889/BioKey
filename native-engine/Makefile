# Variables
CC = gcc
CFLAGS = -fPIC -shared
TARGET = build/biometric_math.so
SRC = src/biometric_math.c

# The command to build the library
all:
	$(CC) $(CFLAGS) -o $(TARGET) $(SRC) -lm

# Clean up the build folder
clean:
	rm -f $(TARGET)