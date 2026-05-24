# Contributing

## StartOS package

The StartOS package lives in `startos/` and uses the Dockerfile at
`umbrel/Dockerfile` to build the service image. The package supports `x86_64`
and `aarch64`.

Install the StartOS packaging prerequisites from the official packaging guide,
then run:

```bash
npm ci
npm run check
npm run build
make
```

Useful targeted builds:

```bash
make x86
make arm
make clean
```

`make install` sideloads the newest local `.s9pk` to the StartOS host configured
in `~/.startos/config.yaml`.

Before opening a Start9 Community Registry PR, verify:

- `npm run check` passes.
- `npm run build` passes.
- Fresh `.s9pk` files are built from the current commit.
- The package has been installed on StartOS, started, launched through its Web UI
  interface, backed up, restored, stopped, uninstalled, and reinstalled.
