BINARY   := zelira
CMD      := ./cmd/zelira
VERSION  := $(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")
LDFLAGS  := -ldflags "-s -w -X github.com/ParkWardRR/zelira/cmd/zelira/commands.version=$(VERSION)"

.PHONY: build clean test linux-amd64 linux-arm64 all

build:
	go build $(LDFLAGS) -o $(BINARY) $(CMD)

linux-amd64:
	GOOS=linux GOARCH=amd64 go build $(LDFLAGS) -o $(BINARY)-linux-amd64 $(CMD)

linux-arm64:
	GOOS=linux GOARCH=arm64 go build $(LDFLAGS) -o $(BINARY)-linux-arm64 $(CMD)

all: linux-amd64 linux-arm64

test:
	go test ./...

clean:
	rm -f $(BINARY) $(BINARY)-linux-*

install: build
	sudo cp $(BINARY) /usr/local/bin/$(BINARY)
