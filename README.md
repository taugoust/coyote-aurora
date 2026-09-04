# Aurora QShell peer bridge

This repository provides the Clara-side endpoint for end-to-end QShell peer-path tests over the existing Rose ↔ Clara QSFP1 cable. It supports a Helios d3 decode and bounded multi-beat opaque-loopback records for isolating QShell control and peer routing from decoder behavior.

## Architecture

```text
Clara host
  │ Coyote H2C/C2H
  ▼
host/Aurora bridge vFPGA
  │ Aurora 64B/66B, QSFP1
  ▼
Rose QShell peer ingress → selected service → QShell peer egress
                              (opaque loopback or Helios d3)
  │
  └──────────────── Aurora correction response ───────────────► Clara host
```

Clara runs a Coyote image with a transparent bidirectional bridge. The legacy Helios d3 test was designed for Rose's aggregate image at Helios commit `ed250d5048f43b98ac2969666f16aaea4980982c`, QShell commit `c4179da5303db1007a6c5ecdc69b8e51c70b1f14`, and bitstream SHA-256 `552286a9828e75aac7cda1f98ea59b4e77df034c04c7d0440d4b4cdb792de7fd`. The opaque-loopback test instead requires a separately accepted Rose image containing the corrected loopback service and resident-control boundary; it does not require rebuilding or reprogramming Clara's bridge image.

The Clara datapath is:

- host receive → two-record atomic queue → Aurora transmit;
- Aurora receive → two-record atomic queue → host transmit.

Each queue accepts the full 4,096-byte QSH2 payload bound: the generated 48-byte header/64-byte beat geometry makes this at most 65 beats. It validates the generated common header, exact declared payload length, contiguous low-lane `tkeep`, and the exact final `tlast` before committing anything. Malformed or over-bound records are drained and dropped atomically. Accepted records preserve the complete `tdata` vector without byte or half-vector transformation and sustain one beat per cycle. Two banks allow the next record to be captured while the current record drains and isolate downstream ready paths.

At link loss, queued host requests and an incomplete peer response are flushed. If host DMA is partway through a request, its old-epoch remainder is accepted and discarded through `tlast`, including if the link reconnects first. A complete correction already accepted from Aurora remains a valid host record and is never retracted under host backpressure.

The Clara Coyote input is pinned to published runtime-stack revision `dc614541f6e060232489dfcfd0e037363f16f48e`. This retains the four-lane 25.78125 Gb/s Aurora framing, 512-bit shell CDC, QSFP1 constraints, Immediate NFC configuration, current narrow control behavior, and driver cleanup used by the matching Rose stack. Host and RTL QSH2 encoding/framing consume generated ABI files from pinned QShell runtime-stack revision `18062942cbdf12dd124e740338ba72530f589e0b`; this repository does not define a second set of wire constants or offsets.

## Device-free validation

```bash
nix build -L .#checks.x86_64-linux.aurora-peer-bridge-stream-regression
nix build -L .#checks.x86_64-linux.aurora-qsh2-host-regression
nix build -L .#checks.x86_64-linux.aurora-loopback-csr-regression
nix build -L .#checks.x86_64-linux.aurora-rose-qsh2-protocol-contract
nix build -L .#aurora-qshell-peer-host
nix flake check --no-build
```

## Build the Clara image

The existing target remains a diagnostic, non-strict build. The separately named strict target enables both Coyote timing checks and implementation enforcement:

```bash
nix build -L .#aurora-qshell-peer-bridge-u280-strict \
  -o result-qshell-peer-bridge-u280-strict --keep-failed
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

Do not run this Clara deployment sequence on Rose. Any Rose personality change is a separate reviewed operation with Rose's own fixed BDF and JTAG target.

## Run the opaque-loopback oracle

First configure Rose service endpoint `20` as available with an exclusive scheduler whose maximum record-beat count covers the request (one for the default payload, 13 for the 760-byte circuit-d9 request payload, or 65 for the bridge maximum). Install capability `1` for context `4660`, physical peer source/correction endpoint `0x80000001`, initial round/version `1/1`, and use `QSHELL_SCHEMA_OPAQUE_LOOPBACK` (`0x00000001`) for both syndrome and correction schemas.

Then run on Clara:

```bash
/nix/store/<host-output>/bin/aurora-qshell-loopback \
  --context 4660 --round 1 --route 1 --route-version 1 \
  --wire-source 305419896 --peer-endpoint 2147483649 \
  --service-endpoint 20 --payload-hex a55a00ff11223344 \
  --device 0 --timeout-ms 2000 --verbose
```

A compact 47-byte framing smoke produces a 95-byte, two-beat record:

```bash
/nix/store/<host-output>/bin/aurora-qshell-loopback \
  --context 4660 --round 1 --route 1 --route-version 1 \
  --wire-source 305419896 --peer-endpoint 2147483649 \
  --service-endpoint 20 \
  --payload-hex 000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e \
  --device 0 --timeout-ms 2000 --verbose
```

The actual MicroBlossom circuit-d9 request is 808 total bytes (760-byte payload, 13 beats), while its maximum result is 3,566 total bytes (3,518-byte payload, 56 beats). The bridge regression exercises both boundaries plus the 4,096-byte payload/65-beat maximum; the compact command above is only a convenient framing smoke.

The oracle requires current ABI magic/version, correction class, opaque schema, preserved context/round/capability/flags/payload, service source endpoint `20`, authenticated peer destination `0x80000001`, active route version `1`, and correction sequence zero. The deliberately different wire source proves Rose replaced the untrusted ingress source before service dispatch.

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
