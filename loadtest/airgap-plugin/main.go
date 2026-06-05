package main

import (
	"net/http"

	"github.com/TykTechnologies/tyk/ctx"
	"github.com/TykTechnologies/tyk/log"
)

var logger = log.Get()

// AddFooBarHeader uses ONLY tyk packages + stdlib (no external plugin deps),
// so a baked tyk module cache is sufficient to build it fully offline.
func AddFooBarHeader(rw http.ResponseWriter, r *http.Request) {
	r.Header.Add("Foo", "Bar")
	logger.Info("airgap plugin")
	if api := ctx.GetDefinition(r); api != nil {
		logger.Info("have api def")
	}
}

func main() {}
