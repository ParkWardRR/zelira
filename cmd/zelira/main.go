package main

import (
	"os"

	"github.com/ParkWardRR/zelira/cmd/zelira/commands"
)

func main() {
	if err := commands.Execute(); err != nil {
		os.Exit(1)
	}
}
