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

## Advanced: 2.31

The 2.31 target exists for one narrow case: your plugin's own C or C++ code calls glibc
functions that were added after 2.17 and no later than 2.31.

This is not a general upgrade path, and it is not needed to match modern Gateway
containers. Newer glibc runtimes can load plugins built with the lower 2.17 floor.

Use 2.31 only when you have a concrete C/C++ dependency that requires it. The cost is
reduced portability: the resulting plugin will not run on RHEL 7 or any host with glibc
older than 2.31.

Maintainers can publish or build opt-in tags with the glibc suffix:

```text
chrisanderton/compile-tyk-plugin:vX.Y.Z-glibc2.31
chrisanderton/compile-tyk-plugin:vX.Y.Z-wolfi-glibc2.31
```

The same target is available as a workflow or base build input:

```yaml
glibc_target: "2.31"
```

```bash
docker build -f Dockerfile.base --build-arg GLIBC_TARGET=2.31 .
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

If the default 2.17 build passes validation and loads, keep it. Move to 2.31 only when
validation fails because your plugin genuinely requires newer glibc symbols.
