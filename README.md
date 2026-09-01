# Aurora QShell peer bridge

This repository provides the Clara-side endpoint for an end-to-end QShell peer-path test over the existing Rose ↔ Clara QSFP1 cable.

## Architecture

```text
Clara host
  │ Coyote H2C/C2H
  ▼
host/Aurora bridge vFPGA
  │ Aurora 64B/66B, QSFP1
  ▼
Rose QShell peer ingress → Helios d3 → QShell peer egress
  │
  └──────────────── Aurora correction response ───────────────► Clara host
```

Rose keeps its accepted aggregate QShell/Helios image unchanged. That deployed image is Helios commit `ed250d5048f43b98ac2969666f16aaea4980982c`, QShell commit `c4179da5303db1007a6c5ecdc69b8e51c70b1f14`, and bitstream SHA-256 `552286a9828e75aac7cda1f98ea59b4e77df034c04c7d0440d4b4cdb792de7fd`. Clara runs a Coyote image with a transparent bidirectional bridge:

- host receive → two-entry registered queue → Aurora transmit;
- Aurora receive → two-entry registered queue → host transmit.

The queues preserve `tdata`, `tkeep`, and `tlast`, isolate downstream ready paths, and sustain one beat per cycle without stalls. This initial bridge accepts only complete one-beat records, matching Helios d3. A request queued toward a failed link is discarded; a complete correction already accepted from Aurora remains a valid host transfer and is never retracted under host backpressure.

The Coyote input is pinned to Rose's exact revision `6b9b0ae2b2928d9d0c9afce4313fcec3f128b705`. This matches the four-lane 25.78125 Gb/s Aurora framing, 512-bit shell CDC, QSFP1 constraints, and Immediate NFC configuration used by the deployed Rose image.

## Device-free validation

```bash
nix build -L .#checks.x86_64-linux.aurora-peer-bridge-stream-regression
nix build -L .#checks.x86_64-linux.aurora-loopback-csr-regression
nix build -L .#aurora-qshell-peer-host
nix flake check --no-build
```

## Build the Clara image

Run the physical build on Rose or another configured build host:

```bash
nix build -L .#aurora-qshell-peer-bridge-u280 \
  -o result-qshell-peer-bridge-u280 --keep-failed
```

A successful Nix command is not sufficient acceptance. Before deployment, inspect the package's canonical timing, routing, DRC, and bitstream reports and require non-negative setup and hold slack, complete routing, and no error-level bitstream DRC findings.

## Copy to Clara

Copy the realized image and host-runner closures; Clara does not rebuild them:

```bash
image_out="$(nix path-info .#aurora-qshell-peer-bridge-u280)"
host_out="$(nix path-info .#aurora-qshell-peer-host)"
driver_out="$(nix path-info .#coyote-driver-ultrascale_plus-clara)"
tools_out="$(nix path-info .#aurora-qshell-peer-clara-deployment-tools)"
nix copy --to ssh://clara "$image_out" "$host_out" "$driver_out" "$tools_out"
```

Retain those exact paths on Clara before deployment, for example with `nix-store --add-root <durable-link> --realise <store-path>`. The driver package uses Clara's pinned Linux 7.1.9 kernel/compiler set; the copied deployment tools contain the generic multifunction-endpoint reset repair.

## Program Clara

On Clara, use BDF `0000:e1:00.0` and JTAG cable `21770327N021A`. The copied tools support the canonical manual deployment sequence without evaluating or rebuilding a flake on Clara:

```bash
export PATH=/nix/store/<tools-output>/bin:$PATH
export FDEV_NAME=u280
export FPGA_BDF=0000:e1:00.0
export FPGA_PART_HINT=xcu280
export FPGA_JTAG_TARGET=21770327N021A
image=/nix/store/<bridge-output>/bitstreams/cyt_top.bit
driver=/nix/store/<driver-output>/coyote_driver.ko

unload-driver
hot-reset
program-cli "$image"
hot-reset
set-hugepages
insert-driver "$driver" "$image"
```

Do not run this sequence on Rose; Rose must retain the accepted QShell/Helios image.

## Run a peer decode

On Clara:

```bash
/nix/store/<host-output>/bin/aurora-qshell-peer --qshell \
  --distance 3 --noise-model phenom \
  --context 4660 --round 1 --route 1 \
  --source-endpoint 305419896 --peer-endpoint 2147483649 \
  --decoder-endpoint 0 --route-version 0 \
  --input-hex 00000000 --expect-correction-hex 000000000000 \
  --device 0 --timeout-ms 2000 --verbose
```

The runner first requires Aurora link-up, reports the active lane mask, transfers the QSH2 record through Coyote, and validates the returned correction's ABI, class, schema, exact d3 payload length, context, round, route capability, endpoint identities, route version, and optional correction oracle. Set `--device` to Clara's actual Coyote device index if it is not zero.

Rose binds physical peer endpoint `0x80000001` (`2147483649`) at ingress. The deliberately different wire source `0x12345678` proves that Rose replaced the untrusted field: the returned correction must target the authenticated peer endpoint. The currently deployed reset/default route reports decoder endpoint/version `0/0`.
