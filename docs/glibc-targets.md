# glibc targets

This compiler targets **glibc 2.17 by default**. That is the RHEL 7 / CentOS 7 ABI
floor and gives plugins the broadest runtime compatibility.

Most users should not change it.

## What the glibc target controls

The target controls the glibc symbols your plugin may require after linking. A plugin
that requires symbols up to glibc *N* can run on hosts with glibc *N* or newer.

The compiler image itself can run a modern base OS. Plugin compatibility comes from an
isolated sysroot under `/opt/tyk/sysroots/`, not from running an old container OS.

## Default: 2.17

Use the default for stock plugins and for any plugin that must run on older native Linux
hosts, including RHEL 7.

The default is the right choice when:

- Your plugin is ordinary Go, or CGO that does not need newer glibc APIs.
- You want the widest compatibility.
- You are building for a stock `tykio/tyk-gateway` image.
- You are unsure which target to choose.

The default compiler tags use this floor, for example:

```bash
docker run --rm -v "$PWD:/plugin-source" \
  chrisanderton/compile-tyk-plugin:vX.Y.Z my-plugin.so
```

## Optional: a custom glibc floor (mechanism, not a recommendation)

The 2.17 default is the right floor for almost everyone, and a newer Gateway container does
**not** require a higher one - newer glibc runtimes can load plugins built with the lower 2.17
floor. The only case for raising the floor is narrow: your plugin's own C or C++ code calls a
glibc function that was added after 2.17. The cost is reduced portability - the resulting plugin
will not run on hosts older than the floor you pick (for example, no longer on RHEL 7).

For that narrow case, the floor is **parameterized** - you can build against a different sysroot
floor. `-glibc2.31` is simply *an example* of the mechanism; the `2.31` value is arbitrary and
carries no special status. Any floor for which you can supply a matching sysroot works the same way.

A custom-floor build is selected with the `GLIBC_TARGET` base build arg, and published as an
optional suffixed tag (here the 2.31 example):

```bash
docker build -f Dockerfile.base --build-arg GLIBC_TARGET=2.31 .
```

```yaml
glibc_target: "2.31"
```

```text
chrisanderton/compile-tyk-plugin:vX.Y.Z-glibc2.31
chrisanderton/compile-tyk-plugin:vX.Y.Z-wolfi-glibc2.31
```

Published images set `TYK_GLIBC_TARGET` for you. Override it only if you also provide a
matching sysroot under `TYK_PLUGIN_SYSROOT_BASE`.

## How to prove the choice

After building a plugin, inspect its required glibc symbols:

```bash
readelf --version-info my-plugin_vX.Y.Z_linux_amd64.so | grep GLIBC
```

The build validator also checks the symbol ceiling. For final confidence, load the plugin
into the exact Gateway build you will run:

```bash
tyk plugin load -f my-plugin_vX.Y.Z_linux_amd64.so -s MySymbol
```

If the default 2.17 build passes validation and loads, keep it. Raise the floor only when
validation fails because your plugin genuinely requires newer glibc symbols.
