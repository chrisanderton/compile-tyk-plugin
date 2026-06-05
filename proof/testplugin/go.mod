module tyk.internal/proof

// Low go-directive floor on purpose: with GOTOOLCHAIN=local the directive is an
// enforced minimum, so this must stay <= the lowest Gateway Go we build a proof
// image for. The plugin is a trivial CGO smoke test and uses no newer-Go features.
go 1.22
